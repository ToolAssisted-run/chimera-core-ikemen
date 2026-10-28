//go:build chimera

// The disk Ikemen GO sees in the Chimera core, the same in the sandbox and in
// the native reference.
//
// Every file call a Go program makes goes through syscall.Syscall or
// Syscall6, and this core's Go has a hook there (go-patches/common/0001):
// chimeraFS below answers every call that names a path or one of its own
// descriptors, and leaves the rest (the console, the files it opens for
// itself) to the system. So no file of the computer is ever read by the game.
//
// The tree, rooted at "/" (which is also the working folder):
//   - the game: the project's zip, read through the descriptor Chimera
//     mounted (never copied in whole; an entry is unpacked when it is opened);
//   - the engine's own files (data/, external/, font/ of the pinned Ikemen GO),
//     built into the core, wherever the game has no file of that name;
//   - what the game writes (save/ and anything else), kept in memory - so it
//     is in savestates.
// Names are found whatever their case, as on Windows, where most MUGEN
// content was made; a listing gives them as they are, sorted.
package main

import (
	"archive/zip"
	"bytes"
	"embed"
	"fmt"
	"io"
	"io/fs"
	"path"
	"sort"
	"strings"
	"sync"
	"syscall"
	"unsafe"
	_ "unsafe" // linkname
)

//go:linkname chimeraFS syscall.chimeraFS
var chimeraFS func(trap, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2 uintptr, err syscall.Errno, handled bool)

//go:embed chimera_engine
var engineFiles embed.FS

// the times every file says it has: 2000-01-01
const fsTime = 946684800

// the first descriptor of this file system, above any the system gives
const firstFd = 1 << 24

type fsNode struct {
	name     string // as it is spelled
	dir      bool
	kids     map[string]*fsNode // by lower-case name
	data     []byte             // a file of the core's (written, or the engine's)
	zf       *zip.File          // a file of the game's zip
	ino      uint64
	modified bool
}

type fsHandle struct {
	node   *fsNode
	data   []byte // a file's bytes while it is open
	pos    int64
	write  bool
	append bool
	dirPos int
	flags  int
}

var fsys struct {
	sync.Mutex
	root    *fsNode
	handles map[int]*fsHandle
	nextIno uint64
	rand    uint64 // getrandom's stream
	gen     uint64 // counts the changes the game made
}

func (n *fsNode) size() int64 {
	if n.zf != nil {
		return int64(n.zf.UncompressedSize64)
	}
	return int64(len(n.data))
}

func newNode(name string, dir bool) *fsNode {
	fsys.nextIno++
	n := &fsNode{name: name, dir: dir, ino: fsys.nextIno}
	if dir {
		n.kids = map[string]*fsNode{}
	}
	return n
}

// walk finds a node by a cleaned path; with make, missing folders are made.
func walk(p string, mkdirs bool) *fsNode {
	n := fsys.root
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." {
			continue
		}
		if !n.dir {
			return nil
		}
		k := n.kids[strings.ToLower(part)]
		if k == nil {
			if !mkdirs {
				return nil
			}
			k = newNode(part, true)
			n.kids[strings.ToLower(part)] = k
		}
		n = k
	}
	return n
}

func cleanPath(p string) string {
	p = strings.ReplaceAll(p, "\\", "/")
	return strings.TrimPrefix(path.Clean("/"+p), "/")
}

// addFile puts a file in the tree; keep says whether one already there stays.
func addFile(p string, data []byte, zf *zip.File, keep bool) {
	p = cleanPath(p)
	dirName, base := path.Split(p)
	if base == "" {
		return
	}
	d := walk(dirName, true)
	if d == nil || !d.dir {
		return
	}
	key := strings.ToLower(base)
	if old := d.kids[key]; old != nil && (keep || old.dir) {
		return
	}
	n := newNode(base, false)
	n.data, n.zf = data, zf
	d.kids[key] = n
}

// hostReader reads a file the system opened for the core (the game's zip).
type hostReader struct{ fd uintptr }

func (h hostReader) ReadAt(p []byte, off int64) (int, error) {
	done := 0
	for done < len(p) {
		r, _, e := syscall.RawSyscall6(syscall.SYS_PREAD64, h.fd, uintptr(unsafe.Pointer(&p[done])), uintptr(len(p)-done), uintptr(off+int64(done)), 0, 0)
		if e != 0 {
			return done, e
		}
		if r == 0 {
			return done, io.EOF
		}
		done += int(r)
	}
	return done, nil
}

func hostOpen(name string) (uintptr, int64, error) {
	p, err := syscall.BytePtrFromString(name)
	if err != nil {
		return 0, 0, err
	}
	fd, _, e := syscall.RawSyscall6(syscall.SYS_OPENAT, uintptr(0xffffffffffffff9c), uintptr(unsafe.Pointer(p)), syscall.O_RDONLY, 0, 0, 0)
	if e != 0 {
		return 0, 0, e
	}
	size, _, e := syscall.RawSyscall(syscall.SYS_LSEEK, fd, 0, 2)
	if e != 0 {
		return 0, 0, e
	}
	return fd, int64(size), nil
}

// gameRoot is the folder of the zip that holds the game: the zip's top, or
// its one folder when everything is in one (a zipped game folder).
func gameRoot(files []*zip.File) string {
	top := ""
	for _, f := range files {
		name := cleanPath(f.Name)
		first, _, more := strings.Cut(name, "/")
		if !more && !f.FileInfo().IsDir() {
			return "" // a file at the top
		}
		if top == "" {
			top = first
		} else if !strings.EqualFold(top, first) {
			return ""
		}
	}
	if top == "" {
		return ""
	}
	return top + "/"
}

// fsStart makes the tree from the game's zip and the engine's files, and
// starts answering.
func fsStart(zipName string) error {
	fsys.root = newNode("", true)
	fsys.handles = map[int]*fsHandle{}
	fsys.rand = 0x9e3779b97f4a7c15

	fd, size, err := hostOpen(zipName)
	if err != nil {
		return err
	}
	zr, err := zip.NewReader(hostReader{fd}, size)
	if err != nil {
		return err
	}
	root := gameRoot(zr.File)
	for _, f := range zr.File {
		name := cleanPath(f.Name)
		if root != "" {
			if len(name) < len(root) || !strings.EqualFold(name[:len(root)], root) {
				continue
			}
			name = name[len(root):]
		}
		if name == "" {
			continue
		}
		if f.FileInfo().IsDir() {
			walk(name, true)
		} else {
			addFile(name, nil, f, false)
		}
	}
	// a game made for an older Ikemen GO gives way to the engine's files
	legacyStart()
	// the engine's own files, where the game has none
	err = fs.WalkDir(engineFiles, "chimera_engine", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := engineFiles.ReadFile(p)
		if err != nil {
			return err
		}
		addFile(strings.TrimPrefix(p, "chimera_engine/"), b, nil, true)
		return nil
	})
	if err != nil {
		return err
	}
	chimeraFS = fsCall
	return nil
}

// fsSeedSaveData puts the project's save data in the game's folder before
// the game starts: a zip with its folders (what Export Save Data makes of
// several files), or a single file, which goes into save/. A name in a zip
// that is not a plain relative path refuses the lot.
func fsSeedSaveData(names []string) error {
	fsys.Lock()
	defer fsys.Unlock()
	for _, name := range names {
		fd, size, err := hostOpen(name)
		if err != nil {
			return fmt.Errorf("%s: %v", name, err)
		}
		data := make([]byte, size)
		if _, err := (hostReader{fd}).ReadAt(data, 0); err != nil && err != io.EOF {
			return fmt.Errorf("%s: %v", name, err)
		}
		syscall.RawSyscall(syscall.SYS_CLOSE, fd, 0, 0)
		if !strings.EqualFold(path.Ext(name), ".zip") {
			addSaved("save/"+path.Base(name), data)
			continue
		}
		zr, err := zip.NewReader(bytes.NewReader(data), size)
		if err != nil {
			return fmt.Errorf("%s: %v", name, err)
		}
		for _, f := range zr.File {
			if f.FileInfo().IsDir() {
				continue
			}
			clean := path.Clean(strings.ReplaceAll(f.Name, "\\", "/"))
			if path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
				return fmt.Errorf("error.save_name_outside"+textInner+"%s"+textInner+"%s", name, f.Name)
			}
			rc, err := f.Open()
			if err != nil {
				return fmt.Errorf("%s: %s: %v", name, f.Name, err)
			}
			b, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return fmt.Errorf("%s: %s: %v", name, f.Name, err)
			}
			addSaved(clean, b)
		}
	}
	return nil
}

// addSaved puts a file of the save data in the tree, over any of the game's.
func addSaved(p string, data []byte) {
	addFile(p, data, nil, false)
	if n := walk(cleanPath(p), false); n != nil {
		n.modified = true
		fsys.gen++
	}
}

// ---- the calls ----------------------------------------------------------------

const atFdcwd = -100

func cstring(p uintptr) string {
	if p == 0 {
		return ""
	}
	var b []byte
	for i := uintptr(0); ; i++ {
		c := *(*byte)(unsafe.Pointer(p + i))
		if c == 0 {
			break
		}
		b = append(b, c)
	}
	return string(b)
}

func bytesAt(p, n uintptr) []byte {
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(p)), n)
}

func ok(v uintptr) (uintptr, uintptr, syscall.Errno, bool) { return v, 0, 0, true }
func fail(e syscall.Errno) (uintptr, uintptr, syscall.Errno, bool) {
	return ^uintptr(0), 0, e, true
}
func pass() (uintptr, uintptr, syscall.Errno, bool) { return 0, 0, 0, false }

func mine(fd uintptr) bool { return int(fd) >= firstFd }

// atPath: a path given with a directory descriptor (the *at calls)
func atPath(dirfd uintptr, p string) (string, bool) {
	if strings.HasPrefix(p, "/") || int(int32(dirfd)) == atFdcwd {
		return cleanPath(p), true
	}
	h := fsys.handles[int(dirfd)]
	if h == nil || !h.node.dir {
		return "", false
	}
	return "", false // no descriptor-relative paths are needed by Ikemen GO
}

func fsCall(trap, a1, a2, a3, a4, a5, a6 uintptr) (uintptr, uintptr, syscall.Errno, bool) {
	switch trap {
	case syscall.SYS_READ, syscall.SYS_WRITE, syscall.SYS_CLOSE, syscall.SYS_FSTAT, syscall.SYS_LSEEK,
		syscall.SYS_PREAD64, syscall.SYS_PWRITE64, syscall.SYS_FCNTL, syscall.SYS_FSYNC, syscall.SYS_FDATASYNC,
		syscall.SYS_FTRUNCATE, syscall.SYS_GETDENTS64, syscall.SYS_FCHMOD, syscall.SYS_FCHOWN, syscall.SYS_FADVISE64,
		syscall.SYS_FSTATFS:
		if !mine(a1) {
			return pass()
		}
	case 318: // getrandom: the same bytes in every run and in both builds
		fsys.Lock()
		b := bytesAt(a1, a2)
		for i := range b {
			fsys.rand += 0x9e3779b97f4a7c15
			z := fsys.rand
			z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
			z = (z ^ (z >> 27)) * 0x94d049bb133111eb
			b[i] = byte(z ^ (z >> 31))
		}
		fsys.Unlock()
		return ok(a2)
	}
	fsys.Lock()
	defer fsys.Unlock()
	switch trap {
	case syscall.SYS_OPENAT:
		p, good := atPath(a1, cstring(a2))
		if !good {
			return fail(syscall.EBADF)
		}
		return fsOpen(p, int(a3))
	case syscall.SYS_OPEN:
		return fsOpen(cleanPath(cstring(a1)), int(a2))
	case syscall.SYS_CLOSE:
		h := fsys.handles[int(a1)]
		if h == nil {
			return fail(syscall.EBADF)
		}
		if h.write {
			h.node.data = h.data
			h.node.zf = nil
		}
		delete(fsys.handles, int(a1))
		return ok(0)
	case syscall.SYS_READ, syscall.SYS_PREAD64:
		h := fsys.handles[int(a1)]
		if h == nil || h.node.dir {
			return fail(syscall.EBADF)
		}
		pos := h.pos
		if trap == syscall.SYS_PREAD64 {
			pos = int64(a4)
		}
		n := 0
		if pos < int64(len(h.data)) {
			n = copy(bytesAt(a2, a3), h.data[pos:])
		}
		if trap == syscall.SYS_READ {
			h.pos += int64(n)
		}
		return ok(uintptr(n))
	case syscall.SYS_WRITE, syscall.SYS_PWRITE64:
		h := fsys.handles[int(a1)]
		if h == nil || !h.write {
			return fail(syscall.EBADF)
		}
		pos := h.pos
		if h.append {
			pos = int64(len(h.data))
		}
		if trap == syscall.SYS_PWRITE64 {
			pos = int64(a4)
		}
		src := bytesAt(a2, a3)
		if end := pos + int64(len(src)); end > int64(len(h.data)) {
			h.data = append(h.data, make([]byte, end-int64(len(h.data)))...)
		}
		copy(h.data[pos:], src)
		if trap == syscall.SYS_WRITE {
			h.pos = pos + int64(len(src))
		}
		h.node.data = h.data
		h.node.zf = nil
		h.node.modified = true
		fsys.gen++
		return ok(a3)
	case syscall.SYS_LSEEK:
		h := fsys.handles[int(a1)]
		if h == nil {
			return fail(syscall.EBADF)
		}
		var base int64
		switch a3 {
		case 1:
			base = h.pos
		case 2:
			base = int64(len(h.data))
		}
		np := base + int64(a2)
		if np < 0 {
			return fail(syscall.EINVAL)
		}
		h.pos = np
		return ok(uintptr(np))
	case syscall.SYS_FSTAT:
		h := fsys.handles[int(a1)]
		if h == nil {
			return fail(syscall.EBADF)
		}
		fillStat(a2, h.node, int64(len(h.data)))
		return ok(0)
	case syscall.SYS_NEWFSTATAT:
		p, good := atPath(a1, cstring(a2))
		if !good {
			return fail(syscall.EBADF)
		}
		if p == "" && a4&0x1000 != 0 { // AT_EMPTY_PATH
			return fail(syscall.EBADF)
		}
		n := walk(p, false)
		if n == nil {
			return fail(syscall.ENOENT)
		}
		fillStat(a3, n, n.size())
		return ok(0)
	case syscall.SYS_STAT, syscall.SYS_LSTAT:
		n := walk(cleanPath(cstring(a1)), false)
		if n == nil {
			return fail(syscall.ENOENT)
		}
		fillStat(a2, n, n.size())
		return ok(0)
	case syscall.SYS_FACCESSAT, 439: // faccessat, faccessat2
		p, good := atPath(a1, cstring(a2))
		if !good {
			return fail(syscall.EBADF)
		}
		if walk(p, false) == nil {
			return fail(syscall.ENOENT)
		}
		return ok(0)
	case syscall.SYS_ACCESS:
		if walk(cleanPath(cstring(a1)), false) == nil {
			return fail(syscall.ENOENT)
		}
		return ok(0)
	case syscall.SYS_GETDENTS64:
		return fsGetdents(a1, a2, a3)
	case syscall.SYS_FCNTL:
		h := fsys.handles[int(a1)]
		if h == nil {
			return fail(syscall.EBADF)
		}
		switch a2 {
		case syscall.F_GETFL:
			return ok(uintptr(h.flags))
		case syscall.F_DUPFD, syscall.F_DUPFD_CLOEXEC:
			fd := fsNewFd(int(a3))
			c := *h
			fsys.handles[fd] = &c
			return ok(uintptr(fd))
		}
		return ok(0)
	case syscall.SYS_FSYNC, syscall.SYS_FDATASYNC, syscall.SYS_FCHMOD, syscall.SYS_FCHOWN, syscall.SYS_FADVISE64:
		if fsys.handles[int(a1)] == nil {
			return fail(syscall.EBADF)
		}
		return ok(0)
	case syscall.SYS_FSTATFS:
		return fail(syscall.ENOSYS)
	case syscall.SYS_FTRUNCATE:
		h := fsys.handles[int(a1)]
		if h == nil || !h.write {
			return fail(syscall.EBADF)
		}
		size := int64(a2)
		if size < int64(len(h.data)) {
			h.data = h.data[:size]
		} else {
			h.data = append(h.data, make([]byte, size-int64(len(h.data)))...)
		}
		h.node.data = h.data
		h.node.zf = nil
		h.node.modified = true
		fsys.gen++
		return ok(0)
	case syscall.SYS_MKDIRAT:
		p, good := atPath(a1, cstring(a2))
		if !good {
			return fail(syscall.EBADF)
		}
		return fsMkdir(p)
	case syscall.SYS_MKDIR:
		return fsMkdir(cleanPath(cstring(a1)))
	case syscall.SYS_UNLINKAT:
		p, good := atPath(a1, cstring(a2))
		if !good {
			return fail(syscall.EBADF)
		}
		return fsRemove(p, a3&0x200 != 0) // AT_REMOVEDIR
	case syscall.SYS_UNLINK:
		return fsRemove(cleanPath(cstring(a1)), false)
	case syscall.SYS_RMDIR:
		return fsRemove(cleanPath(cstring(a1)), true)
	case syscall.SYS_RENAMEAT, 316: // renameat, renameat2
		from, good1 := atPath(a1, cstring(a2))
		to, good2 := atPath(a3, cstring(a4))
		if !good1 || !good2 {
			return fail(syscall.EBADF)
		}
		return fsRename(from, to)
	case syscall.SYS_RENAME:
		return fsRename(cleanPath(cstring(a1)), cleanPath(cstring(a2)))
	case syscall.SYS_READLINKAT, syscall.SYS_READLINK:
		return fail(syscall.EINVAL)
	case syscall.SYS_GETCWD:
		if a2 < 2 {
			return fail(syscall.ERANGE)
		}
		b := bytesAt(a1, 2)
		b[0], b[1] = '/', 0
		return ok(2)
	case syscall.SYS_CHDIR:
		if n := walk(cleanPath(cstring(a1)), false); n == nil || !n.dir {
			return fail(syscall.ENOENT)
		}
		return ok(0) // there is one working folder, the top
	case syscall.SYS_UTIMENSAT, syscall.SYS_FCHMODAT, syscall.SYS_FCHOWNAT, syscall.SYS_SYMLINKAT, syscall.SYS_LINKAT:
		return fail(syscall.EPERM)
	case 332: // statx: Go's os does not use it; nothing here answers it
		return fail(syscall.ENOSYS)
	}
	return pass()
}

func fsNewFd(from int) int {
	fd := firstFd
	if from > fd {
		fd = from
	}
	for fsys.handles[fd] != nil {
		fd++
	}
	return fd
}

func fsOpen(p string, flags int) (uintptr, uintptr, syscall.Errno, bool) {
	acc := flags & 3
	n := walk(p, false)
	if n == nil {
		if flags&syscall.O_CREAT == 0 {
			return fail(syscall.ENOENT)
		}
		dirName, base := path.Split(p)
		d := walk(dirName, false)
		if d == nil || !d.dir || base == "" {
			return fail(syscall.ENOENT)
		}
		n = newNode(base, false)
		n.data = []byte{}
		n.modified = true
		d.kids[strings.ToLower(base)] = n
		fsys.gen++
	} else if flags&syscall.O_CREAT != 0 && flags&syscall.O_EXCL != 0 {
		return fail(syscall.EEXIST)
	}
	if n.dir && acc != syscall.O_RDONLY {
		return fail(syscall.EISDIR)
	}
	if !n.dir && flags&syscall.O_DIRECTORY != 0 {
		return fail(syscall.ENOTDIR)
	}
	h := &fsHandle{node: n, flags: flags, write: acc != syscall.O_RDONLY, append: flags&syscall.O_APPEND != 0}
	if !n.dir {
		if n.zf != nil && !(h.write && flags&syscall.O_TRUNC != 0) {
			rc, err := n.zf.Open()
			if err != nil {
				return fail(syscall.EIO)
			}
			b, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return fail(syscall.EIO)
			}
			h.data = b
		} else {
			h.data = n.data
		}
		if h.write {
			if flags&syscall.O_TRUNC != 0 {
				h.data = []byte{}
			} else {
				h.data = append([]byte(nil), h.data...)
			}
			n.data, n.zf, n.modified = h.data, nil, true
			fsys.gen++
		}
	}
	fd := fsNewFd(firstFd)
	fsys.handles[fd] = h
	return ok(uintptr(fd))
}

func fsMkdir(p string) (uintptr, uintptr, syscall.Errno, bool) {
	if p == "" || walk(p, false) != nil {
		return fail(syscall.EEXIST)
	}
	dirName, _ := path.Split(p)
	if d := walk(dirName, false); d == nil || !d.dir {
		return fail(syscall.ENOENT)
	}
	walk(p, true)
	return ok(0)
}

func fsRemove(p string, dir bool) (uintptr, uintptr, syscall.Errno, bool) {
	dirName, base := path.Split(p)
	d := walk(dirName, false)
	if d == nil || !d.dir || base == "" {
		return fail(syscall.ENOENT)
	}
	n := d.kids[strings.ToLower(base)]
	if n == nil {
		return fail(syscall.ENOENT)
	}
	if dir != n.dir {
		if dir {
			return fail(syscall.ENOTDIR)
		}
		return fail(syscall.EISDIR)
	}
	if n.dir && len(n.kids) != 0 {
		return fail(syscall.ENOTEMPTY)
	}
	delete(d.kids, strings.ToLower(base))
	fsys.gen++
	return ok(0)
}

func fsRename(from, to string) (uintptr, uintptr, syscall.Errno, bool) {
	fd, fb := path.Split(from)
	td, tb := path.Split(to)
	fdir, tdir := walk(fd, false), walk(td, false)
	if fdir == nil || tdir == nil || !tdir.dir || fb == "" || tb == "" {
		return fail(syscall.ENOENT)
	}
	n := fdir.kids[strings.ToLower(fb)]
	if n == nil {
		return fail(syscall.ENOENT)
	}
	delete(fdir.kids, strings.ToLower(fb))
	n.name = tb
	n.modified = true
	tdir.kids[strings.ToLower(tb)] = n
	fsys.gen++
	return ok(0)
}

func fillStat(p uintptr, n *fsNode, size int64) {
	st := (*syscall.Stat_t)(unsafe.Pointer(p))
	*st = syscall.Stat_t{}
	st.Dev = 1
	st.Ino = n.ino
	st.Nlink = 1
	st.Mode = syscall.S_IFREG | 0644
	if n.dir {
		st.Mode = syscall.S_IFDIR | 0755
		st.Nlink = 2
	}
	st.Uid, st.Gid = 1000, 1000
	st.Size = size
	st.Blksize = 4096
	st.Blocks = (size + 511) / 512
	st.Atim.Sec, st.Mtim.Sec, st.Ctim.Sec = fsTime, fsTime, fsTime
}

func fsGetdents(fd, buf, size uintptr) (uintptr, uintptr, syscall.Errno, bool) {
	h := fsys.handles[int(fd)]
	if h == nil {
		return fail(syscall.EBADF)
	}
	if !h.node.dir {
		return fail(syscall.ENOTDIR)
	}
	names := make([]string, 0, len(h.node.kids))
	for _, k := range h.node.kids {
		names = append(names, k.name)
	}
	sort.Strings(names)
	out := bytesAt(buf, size)
	var w bytes.Buffer
	for h.dirPos < len(names) {
		k := h.node.kids[strings.ToLower(names[h.dirPos])]
		reclen := (19 + len(k.name) + 1 + 7) &^ 7
		if w.Len()+reclen > len(out) {
			break
		}
		rec := make([]byte, reclen)
		*(*uint64)(unsafe.Pointer(&rec[0])) = k.ino
		*(*int64)(unsafe.Pointer(&rec[8])) = int64(h.dirPos + 1)
		*(*uint16)(unsafe.Pointer(&rec[16])) = uint16(reclen)
		rec[18] = 8 // DT_REG
		if k.dir {
			rec[18] = 4 // DT_DIR
		}
		copy(rec[19:], k.name)
		w.Write(rec)
		h.dirPos++
	}
	if w.Len() == 0 && h.dirPos < len(names) {
		return fail(syscall.EINVAL)
	}
	copy(out, w.Bytes())
	return ok(uintptr(w.Len()))
}

// ---- what the game wrote (Emulator > Export Save Data) ---------------------------

// savedFiles lists every file the game wrote, by its path, sorted.
func savedFiles() []string {
	fsys.Lock()
	defer fsys.Unlock()
	var out []string
	var visit func(n *fsNode, p string)
	visit = func(n *fsNode, p string) {
		for _, k := range n.kids {
			kp := path.Join(p, k.name)
			if k.dir {
				visit(k, kp)
			} else if k.modified {
				out = append(out, kp)
			}
		}
	}
	visit(fsys.root, "")
	sort.Strings(out)
	return out
}

// fileBytes is a file's bytes as they are now (nil if there is none).
func fileBytes(p string) []byte {
	fsys.Lock()
	defer fsys.Unlock()
	n := walk(cleanPath(p), false)
	if n == nil || n.dir || n.zf != nil {
		return nil
	}
	return n.data
}

// fsGeneration counts the changes the game has made to its files.
func fsGeneration() uint64 {
	fsys.Lock()
	defer fsys.Unlock()
	return fsys.gen
}
