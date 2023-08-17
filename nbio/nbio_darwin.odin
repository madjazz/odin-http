//+private
package nbio

import "core:c"
import "core:os"
import "core:time"
import "core:mem"
import "core:net"

import "../kqueue"

KQueue :: struct {
	fd:              os.Handle,
	io_inflight:     int,
	completion_pool: Pool(Completion),
	timeouts:        [dynamic]^Completion,
	completed:       [dynamic]^Completion,
	io_pending:      [dynamic]^Completion,
	allocator:       mem.Allocator,
}

Completion :: struct {
	operation:     Operation,
	callback:      proc(kq: ^KQueue, c: ^Completion),
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(io: ^IO, _: u32 = DEFAULT_ENTRIES, _: u32 = 0, allocator := context.allocator) -> (err: os.Errno) {
	kq := new(KQueue, allocator)
	defer if err != os.ERROR_NONE do free(kq, allocator)

	qerr: kqueue.Queue_Error
	kq.fd, qerr = kqueue.kqueue()
	if qerr != .None do return kq_err_to_os_err(qerr)

	pool_init(&kq.completion_pool, allocator = allocator)

	kq.timeouts = make([dynamic]^Completion, allocator)
	kq.completed = make([dynamic]^Completion, allocator)
	kq.io_pending = make([dynamic]^Completion, allocator)

	kq.allocator = allocator
	io.impl_data = kq
	return
}

_destroy :: proc(io: ^IO) {
	kq := cast(^KQueue)io.impl_data

	delete(kq.timeouts)
	delete(kq.completed)
	delete(kq.io_pending)

	os.close(kq.fd)

	pool_destroy(&kq.completion_pool)

	free(kq, kq.allocator)
}

// TODO: should this be the entries parameter?
MAX_EVENTS :: 256

_tick :: proc(io: ^IO) -> os.Errno {
	return flush(io, wait_for_completions = false)
}

flush :: proc(io: ^IO, wait_for_completions: bool) -> os.Errno {
	kq := cast(^KQueue)io.impl_data

	events: [MAX_EVENTS]kqueue.KEvent

	next_timeout := flush_timeouts(kq)
	change_events := flush_io(kq, events[:])

	if (change_events > 0 || len(kq.completed) == 0) {
		ts: kqueue.Time_Spec

		if (change_events == 0 && len(kq.completed) == 0) {
			if (wait_for_completions) {
				timeout := next_timeout.(i64) or_else panic("blocking forever")
				ts.nsec = timeout % NANOSECONDS_PER_SECOND
				ts.sec = c.long(timeout / NANOSECONDS_PER_SECOND)
			} else if (kq.io_inflight == 0) {
				return os.ERROR_NONE
			}
		}

		new_events, err := kqueue.kevent(kq.fd, events[:change_events], events[:], &ts)
		if err != .None do return ev_err_to_os_err(err)

		for _ in 0 ..< change_events {
			unordered_remove(&kq.io_pending, 0)
		}

		kq.io_inflight += change_events
		kq.io_inflight -= new_events

		// TODO(perf): don't do this and after the resize to 0, exec callbacks for these events.
		// This is an unnecessary append to then directly remove outside of this if.
		reserve(&kq.completed, new_events)
		for event in events[:new_events] {
			completion := cast(^Completion)event.udata
			append(&kq.completed, completion)
		}
	}

	for completed in &kq.completed {
		completed.callback(kq, completed)
	}
	resize(&kq.completed, 0)

	return os.ERROR_NONE
}

flush_io :: proc(kq: ^KQueue, events: []kqueue.KEvent) -> int {
	events := events
	for event, i in &events {
		if len(kq.io_pending) <= i do return i
		completion := kq.io_pending[i]

		switch op in completion.operation {
		case Op_Accept:
			event.ident = uintptr(os.Socket(op))
			event.filter = kqueue.EVFILT_READ
		case Op_Connect:
			event.ident = uintptr(op.socket)
			event.filter = kqueue.EVFILT_WRITE
		case Op_Read:
			event.ident = uintptr(op.fd)
			event.filter = kqueue.EVFILT_READ
		case Op_Write:
			event.ident = uintptr(op.fd)
			event.filter = kqueue.EVFILT_WRITE
		case Op_Recv:
			event.ident = uintptr(os.Socket(net.any_socket_to_socket(op.socket)))
			event.filter = kqueue.EVFILT_READ
		case Op_Send:
			event.ident = uintptr(os.Socket(net.any_socket_to_socket(op.socket)))
			event.filter = kqueue.EVFILT_WRITE
		case Op_Timeout, Op_Close:
			panic("invalid completion operation queued")
		}

		event.flags = kqueue.EV_ADD | kqueue.EV_ENABLE | kqueue.EV_ONESHOT
		event.udata = completion
	}

	return len(events)
}

flush_timeouts :: proc(kq: ^KQueue) -> (min_timeout: Maybe(i64)) {
	now := time.to_unix_nanoseconds(time.now())

	for i := len(kq.timeouts) - 1; i >= 0; i -= 1 {
		completion := kq.timeouts[i]

		timeout, ok := completion.operation.(Op_Timeout)
		if !ok do panic("non-timeout operation found in the timeouts queue")

		expires := time.to_unix_nanoseconds(timeout.expires)
		if now >= expires {
			ordered_remove(&kq.timeouts, i)
			append(&kq.completed, completion)
			continue
		}

		timeout_ns := expires - now
		if min, has_min_timeout := min_timeout.(i64); has_min_timeout {
			if timeout_ns < min {
				min_timeout = timeout_ns
			}
		} else {
			min_timeout = timeout_ns
		}
	}

	return
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	errno := os.listen(os.Socket(socket), backlog)
	return net.Listen_Error(errno)
}

Op_Accept :: distinct net.TCP_Socket

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Accept(socket)

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Accept)
		callback := cast(On_Accept)completion.user_callback

		client, source, err := net.accept_tcp(net.TCP_Socket(op))
		if err == net.Accept_Error.Would_Block {
			append(&kq.io_pending, completion)
			return
		}

		if err == nil {
			err = prepare(client)
		}

		if err != nil {
			net.close(client)
			callback(completion.user_data, {}, {}, err)
		} else {
			callback(completion.user_data, client, source, nil)
		}

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Close :: distinct os.Handle

// Wraps os.close using the kqueue.
_close :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Close) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Close(fd)

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Close)
		ok := os.close(os.Handle(op))

		callback := cast(On_Close)completion.user_callback
		callback(completion.user_data, ok)

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Connect :: struct {
	socket:    net.TCP_Socket,
	sockaddr:  os.SOCKADDR_STORAGE_LH,
	initiated: bool,
}

// TODO: maybe call this dial?
_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	kq := cast(^KQueue)io.impl_data

	if endpoint.port == 0 {
		callback(user, {}, net.Dial_Error.Port_Required)
		return
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		callback(user, {}, err)
		return
	}

	if err := prepare(sock); err != nil {
		net.close(sock)
		callback(user, {}, err)
		return
	}

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Connect {
		socket   = sock.(net.TCP_Socket),
		sockaddr = _endpoint_to_sockaddr(endpoint),
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := &completion.operation.(Op_Connect)
		callback := cast(On_Connect)completion.user_callback
		defer op.initiated = true

		err: os.Errno
		if op.initiated {
			// We have already called os.connect, retrieve error number only.
			os.getsockopt(os.Socket(op.socket), os.SOL_SOCKET, os.SO_ERROR, &err, size_of(os.Errno))
		} else {
			err = os.connect(os.Socket(op.socket), (^os.SOCKADDR)(&op.sockaddr), i32(op.sockaddr.len))
			if err == os.EINPROGRESS {
				append(&kq.io_pending, completion)
				return
			}
		}

		if err != os.ERROR_NONE {
			net.close(op.socket)
			callback(completion.user_data, {}, net.Dial_Error(err))
		} else {
			callback(completion.user_data, op.socket, nil)
		}

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Read :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Read {
		fd  = fd,
		buf = buf,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Read)

		read, err := os.read(op.fd, op.buf)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}


		callback := cast(On_Read)completion.user_callback
		callback(completion.user_data, read, err)

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Recv :: struct {
	socket: net.Any_Socket,
	buf:    []byte,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Recv {
		socket = socket,
		buf    = buf,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Recv)

		received: int
		err: net.Network_Error
		remote_endpoint: net.Endpoint
		switch sock in op.socket {
		case net.TCP_Socket:
			received, err = net.recv_tcp(sock, op.buf)

			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.TCP_Recv_Error.Timeout {
				append(&kq.io_pending, completion)
				return
			}
		case net.UDP_Socket:
			received, remote_endpoint, err = net.recv_udp(sock, op.buf)

			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.UDP_Recv_Error.Timeout {
				append(&kq.io_pending, completion)
				return
			}
		}

		callback := cast(On_Recv)completion.user_callback
		callback(completion.user_data, received, remote_endpoint, err)

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Send :: struct {
	socket:   net.Any_Socket,
	buf:      []byte,
	endpoint: Maybe(net.Endpoint),
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
) {
	kq := cast(^KQueue)io.impl_data

	if _, ok := socket.(net.UDP_Socket); ok {
		assert(endpoint != nil)
	}

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Send {
		socket   = socket,
		buf      = buf,
		endpoint = endpoint,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Send)

		sent: u32
		errno: os.Errno
		err: net.Network_Error

		switch sock in op.socket {
		case net.TCP_Socket:
			sent, errno = os.send(os.Socket(sock), op.buf, 0)
			err = net.TCP_Send_Error(errno)

		case net.UDP_Socket:
			toaddr := _endpoint_to_sockaddr(op.endpoint.(net.Endpoint))
			sent, errno = os.sendto(os.Socket(sock), op.buf, 0, cast(^os.SOCKADDR)&toaddr, i32(toaddr.len))
			err = net.UDP_Send_Error(errno)
		}

		if errno == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(On_Sent)completion.user_callback
		callback(completion.user_data, int(sent), err)

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Write :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Write {
		fd  = fd,
		buf = buf,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Write)

		written, err := os.write(op.fd, op.buf)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(On_Write)completion.user_callback
		callback(completion.user_data, written, err)

		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.completed, completion)
}

Op_Timeout :: struct {
	expires: time.Time,
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	kq := cast(^KQueue)io.impl_data

	completion := pool_get(&kq.completion_pool)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		callback := cast(On_Timeout)completion.user_callback
		callback(completion.user_data)
		pool_put(&kq.completion_pool, completion)
	}

	append(&kq.timeouts, completion)
}

@(private = "file")
kq_err_to_os_err :: proc(err: kqueue.Queue_Error) -> os.Errno {
	switch err {
	case .Out_Of_Memory:
		return os.ENOMEM
	case .Descriptor_Table_Full:
		return os.EMFILE
	case .File_Table_Full:
		return os.ENFILE
	case .Unknown:
		return os.EFAULT
	case .None:
		fallthrough
	case:
		return os.ERROR_NONE
	}
}

@(private = "file")
ev_err_to_os_err :: proc(err: kqueue.Event_Error) -> os.Errno {
	switch err {
	case .Access_Denied:
		return os.EACCES
	case .Invalid_Event:
		return os.EFAULT
	case .Invalid_Descriptor:
		return os.EBADF
	case .Signal:
		return os.EINTR
	case .Invalid_Timeout_Or_Filter:
		return os.EINVAL
	case .Event_Not_Found:
		return os.ENOENT
	case .Out_Of_Memory:
		return os.ENOMEM
	case .Process_Not_Found:
		return os.ESRCH
	case .Unknown:
		return os.EFAULT
	case .None:
		fallthrough
	case:
		return os.ERROR_NONE
	}
}

// Private proc in net package, verbatim copy.
_endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: os.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case net.IP4_Address:
		(^os.sockaddr_in)(&sockaddr)^ = os.sockaddr_in {
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(os.in_addr)a,
			sin_family = u8(os.AF_INET),
			sin_len    = size_of(os.sockaddr_in),
		}
		return
	case net.IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(os.in6_addr)a,
			sin6_family = u8(os.AF_INET6),
			sin6_len    = size_of(os.sockaddr_in6),
		}
		return
	}
	unreachable()
}