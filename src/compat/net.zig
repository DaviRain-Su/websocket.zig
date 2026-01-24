const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const ionet = std.Io.net;

pub const has_unix_sockets = ionet.has_unix_sockets;

fn defaultIo() Io {
    // Use the global single-threaded IO implementation with networking enabled.
    return Io.Threaded.global_single_threaded.io();
}

pub const Address = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
    un: posix.sockaddr.un,

    pub fn getOsSockLen(self: *const Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => @sizeOf(posix.sockaddr.in),
            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
            posix.AF.UNIX => @sizeOf(posix.sockaddr.un),
            else => @sizeOf(posix.sockaddr),
        };
    }

    pub fn parseIp(text: []const u8, port: u16) !Address {
        return parseIpInternal(text, port);
    }

    pub fn format(self: Address, w: anytype) !void {
        return fmtAddress(self, "", .{}, w);
    }
};

fn ipToPosix(addr: ionet.IpAddress) Address {
    var storage: Io.Threaded.PosixAddress = undefined;
    _ = Io.Threaded.addressToPosix(&addr, &storage);
    var result: Address = undefined;
    result.any = storage.any;
    return result;
}

pub fn parseIpInternal(text: []const u8, port: u16) !Address {
    const ip = try ionet.IpAddress.parse(text, port);
    return ipToPosix(ip);
}

pub fn initUnix(path: []const u8) !Address {
    var addr: Address = undefined;
    if (path.len >= addr.un.path.len) return error.NameTooLong;
    // zero the path then copy
    @memset(&addr.un.path, 0);
    addr.un.family = posix.AF.UNIX;
    @memcpy(addr.un.path[0..path.len], path);
    return addr;
}

pub const Stream = struct {
    inner: ionet.Stream,
    io: Io,
    handle: ionet.Socket.Handle,

    pub const Reader = struct {
        interface: Io.Reader,
        stream: Stream,
        err: ?Error = null,

        pub const Error = error{Timeout, ConnectionResetByPeer};

        pub fn init(stream: Stream, buffer: []u8) Reader {
            return .{
                .interface = .{
                    .vtable = &.{ .stream = streamImpl },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
                .stream = stream,
                .err = null,
            };
        }

        fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
            const dest = limit.slice(try io_w.writableSliceGreedy(1));
            const n = posix.read(r.stream.handle, dest) catch |err| {
                r.err = mapReadError(err);
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            io_w.advance(n);
            return n;
        }
    };

    pub const Writer = struct {
        interface: Io.Writer,
        stream: Stream,
        err: ?Error = null,

        pub const Error = error{Timeout, ConnectionResetByPeer};

        pub fn init(stream: Stream, buffer: []u8) Writer {
            return .{
                .interface = .{
                    .vtable = &.{ .drain = drain, .sendFile = sendFile },
                    .buffer = buffer,
                },
                .stream = stream,
                .err = null,
            };
        }

        fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            const buffered = io_w.buffered();
            var total_len: usize = buffered.len;

            for (data) |chunk| {
                total_len += chunk.len * splat;
            }

            writeAllPosix(w.stream.handle, buffered) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };

            for (data) |chunk| {
                var repeat: usize = 0;
                while (repeat < splat) : (repeat += 1) {
                    writeAllPosix(w.stream.handle, chunk) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                }
            }

            return io_w.consume(total_len);
        }

        fn sendFile(io_w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
            return Io.Writer.unimplementedSendFile(io_w, file_reader, limit);
        }
    };

    pub fn read(self: *const Stream, buf: []u8) !usize {
        return readPosix(self.handle, buf);
    }

    pub fn writeAll(self: *const Stream, data: []const u8) !void {
        try writeAllPosix(self.handle, data);
    }

    pub fn reader(self: *const Stream, buffer: []u8) Reader {
        return Reader.init(self.*, buffer);
    }

    pub fn readAtLeast(self: *const Stream, buf: []u8, at_least: usize) !usize {
        var total: usize = 0;
        while (total < at_least) {
            const n = try self.read(buf[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
        return total;
    }

    pub fn writer(self: *const Stream, buffer: []u8) Writer {
        return Writer.init(self.*, buffer);
    }

    pub fn close(self: *const Stream) void {
        _ = posix.system.close(self.handle);
    }

    fn mapReadError(err: anyerror) Reader.Error {
        return switch (err) {
            error.WouldBlock => error.Timeout,
            error.ConnectionResetByPeer => error.ConnectionResetByPeer,
            else => error.ConnectionResetByPeer,
        };
    }

    fn mapWriteError(err: anyerror) Writer.Error {
        return switch (err) {
            error.WouldBlock => error.Timeout,
            error.ConnectionResetByPeer, error.BrokenPipe => error.ConnectionResetByPeer,
            else => error.ConnectionResetByPeer,
        };
    }

    fn readPosix(handle: posix.fd_t, buf: []u8) Reader.Error!usize {
        return posix.read(handle, buf) catch |err| {
            return mapReadError(err);
        };
    }

    fn writePosix(handle: posix.fd_t, data: []const u8) Writer.Error!usize {
        if (data.len == 0) return 0;
        while (true) {
            const rc = posix.system.write(handle, data.ptr, data.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.Timeout,
                .PIPE, .CONNRESET => return error.ConnectionResetByPeer,
                else => return error.ConnectionResetByPeer,
            }
        }
    }

    fn writeAllPosix(handle: posix.fd_t, data: []const u8) Writer.Error!void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = try writePosix(handle, remaining);
            remaining = remaining[n..];
        }
    }
};

pub fn streamFromHandle(fd: ionet.Socket.Handle) Stream {
    const io = defaultIo();
    return .{
        .inner = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } },
        .io = io,
        .handle = fd,
    };
}

fn connectPosix(address: Address) !Stream {
    const family = address.any.family;
    const socket_proto: u32 = if (family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;
    const sock = posix.system.socket(family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, socket_proto);
    const sock_signed: isize = @as(isize, sock);
    if (sock_signed < 0) return error.NetworkDown;
    const rc = posix.system.connect(@intCast(sock_signed), &address.any, address.getOsSockLen());
    const rc_signed: isize = @as(isize, rc);
    if (rc_signed < 0) return error.NetworkDown;
    return streamFromHandle(@intCast(sock_signed));
}

pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
    _ = allocator; // retained for API compatibility
    const addr = try parseIpInternal(host, port);
    return connectPosix(addr);
}

pub fn tcpConnectToAddress(address: Address) !Stream {
    if (address.any.family == posix.AF.UNIX) {
        return connectPosix(address);
    }
    return connectPosix(address);
}

pub fn AddressFormatter(address: Address) std.fmt.Formatter(fmtAddress) {
    return .{ .data = address };
}

fn fmtAddress(address: Address, comptime layout: []const u8, opts: std.fmt.Options, writer: anytype) !void {
    _ = layout;
    _ = opts;
    switch (address.any.family) {
        posix.AF.UNIX => {
            const path = std.mem.span(@as([*:0]const u8, @ptrCast(&address.un.path)));
            try writer.print("unix:{s}", .{path});
        },
        posix.AF.INET, posix.AF.INET6 => {
            var storage: Io.Threaded.PosixAddress = .{ .any = address.any };
            const ip = Io.Threaded.addressFromPosix(&storage);
            try writer.print("{any}", .{ip});
        },
        else => try writer.print("<af:{d}>", .{address.any.family}),
    }
}
