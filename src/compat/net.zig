const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const ionet = std.Io.net;

pub const has_unix_sockets = ionet.has_unix_sockets;

fn defaultIo() Io {
    // Use the global single-threaded IO implementation. This keeps things
    // simple and avoids pulling in the concurrent runtime for now.
    return Io.Threaded.global_single_threaded.ioBasic();
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

    pub const Reader = ionet.Stream.Reader;
    pub const Writer = ionet.Stream.Writer;

    pub fn read(self: *const Stream, buf: []u8) !usize {
        const rc = posix.system.read(self.handle, buf.ptr, buf.len);
        const n: isize = @bitCast(rc);
        if (n < 0) return error.ConnectionResetByPeer;
        if (n == 0) return 0;
        return @intCast(n);
    }

    pub fn writeAll(self: *const Stream, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const rc = posix.system.write(self.handle, remaining.ptr, remaining.len);
            const n: isize = @bitCast(rc);
            if (n <= 0) return error.ConnectionResetByPeer;
            remaining = remaining[@intCast(n)..];
        }
    }

    pub fn reader(self: *const Stream, buffer: []u8) Reader {
        return Reader.init(self.inner, self.io, buffer);
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
        return Writer.init(self.inner, self.io, buffer);
    }

    pub fn close(self: *const Stream) void {
        _ = posix.system.close(self.handle);
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
