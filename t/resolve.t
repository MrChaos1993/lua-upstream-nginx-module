# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Net::DNS::Nameserver;
use IO::Socket::INET;

our $DNS_PORT = $ENV{TEST_DNS_PORT} || 19053;
$ENV{TEST_NGINX_DNS_PORT} = $DNS_PORT;

our $STATE_PATH = "/tmp/lua-upstream-dns-state-$$";
$ENV{TEST_NGINX_DNS_STATE} = $STATE_PATH;

{
    open my $fh, '>', $STATE_PATH or die "open $STATE_PATH: $!";
    print $fh "10\n";
    close $fh;
}

our $DNS_PID;
{
    my $pid = fork;
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        my $ns = Net::DNS::Nameserver->new(
            LocalAddr    => '127.0.0.1',
            LocalPort    => $DNS_PORT,
            ReplyHandler => sub {
                my ($qname, $qclass, $qtype) = @_;
                my @ans;
                if ($qtype eq 'A') {
                    my $oct = '10';
                    if (open my $fh, '<', $STATE_PATH) {
                        my $line = <$fh>;
                        close $fh;
                        if (defined $line) {
                            chomp $line;
                            $oct = $line if $line =~ /^\d+$/;
                        }
                    }
                    push @ans, Net::DNS::RR->new("$qname. 1 IN A 127.0.0.$oct");
                }
                return ('NOERROR', \@ans, [], [], { aa => 1 });
            },
            Verbose => 0,
        ) or die "Net::DNS::Nameserver init failed";
        $ns->main_loop;
        exit 0;
    }
    $DNS_PID = $pid;
}

{
    my $tries = 0;
    while ($tries++ < 50) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $DNS_PORT,
            Proto    => 'udp',
        );
        last if $sock;
        select(undef, undef, undef, 0.1);
    }
}

END {
    if ($DNS_PID) {
        kill 'TERM', $DNS_PID;
        waitpid($DNS_PID, 0);
    }
    unlink $STATE_PATH if $STATE_PATH;
}

repeat_each(1);

plan tests => repeat_each() * (blocks() * 3);

no_long_string();
run_tests();

__DATA__

=== TEST 1: re-resolution swaps the peer set
--- http_config
    resolver 127.0.0.1:$TEST_NGINX_DNS_PORT valid=1s ipv6=off;
    upstream foo {
        server testhost.local resolve;
    }

    init_by_lua_block {
        DNS_STATE_PATH = "$TEST_NGINX_DNS_STATE"
    }
--- config
    location /proxy {
        proxy_connect_timeout 200ms;
        proxy_pass http://foo/;
    }
    location /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"

            local function write_state(oct)
                local f = assert(io.open(DNS_STATE_PATH, "w"))
                f:write(tostring(oct), "\n")
                f:close()
            end

            local function trigger_and_read(unwanted)
                for _ = 1, 30 do
                    ngx.location.capture("/proxy")
                    ngx.sleep(0.1)
                    local peers = upstream.get_primary_peers("foo")
                    if peers and #peers > 0 and peers[1].name ~= unwanted then
                        return peers[1].name
                    end
                end
                return "<timeout>"
            end

            write_state(10)
            local before = trigger_and_read()

            write_state(20)
            ngx.sleep(1.2)
            local after = trigger_and_read(before)

            ngx.say(before, " -> ", after)
        }
    }
--- request
    GET /t
--- response_body
127.0.0.10:80 -> 127.0.0.20:80
--- no_error_log
[error]
