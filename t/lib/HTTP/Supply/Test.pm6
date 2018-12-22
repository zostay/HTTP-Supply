use v6;

unit class HTTP::Supply::Test;

use Test;

has @.tests;
has Bool $.debug = ?%*ENV<HTTP_SUPPLY_TEST_DEBUG> // False;

multi method await-or-timeout(Promise:D $p, Int :$seconds = 5, :$message) {
    await Promise.anyof($p, Promise.in($seconds));
    if $p {
        $p.result;
    }
    else {
        die "operation timed out after $seconds seconds"
            ~ ($message ?? ": $message" !! "");
    }
}

multi method await-or-timeout(@p, Int :$seconds = 5, :$message) {
    self.await-or-timeout(Promise.allof(@p), :$seconds, :$message);
}

method file-reader($test-file, :$size) {
    $test-file.open(:r, :bin).Supply(:$size)
}

method socket-reader($test-file, :$size) {
    my Int $port = (rand * 1000 + 10000).Int;

    my $listener = do {
        # note "# new listener";
        my $listener = IO::Socket::Async.listen('127.0.0.1', $port);

        my $promised-tap = Promise.new;
        sub close-tap {
            self.await-or-timeout(
                $promised-tap.then({ .result.close }),
                :message<connection close>,
            );
        }

        $promised-tap.keep($listener.act: {
            CATCH {
                default { .warn; .rethrow }
            }

            # note "# accepted $*THREAD.id()";
            my $input = $test-file.open(:r, :bin);
            while $input.read($size) -> $chunk {
                # note "# write ", $chunk;
                self.await-or-timeout(.write($chunk), :message<writing chunk>);
            }
            # note "# closing";
            .close;
            # note "# closed";
            close-tap;
            # note "# not listening";
        });

        # note "# ready to connect";
        $listener;
    }

    # When we get here, we should be ready to connect to ourself on the other
    # thread.
    my $conn = self.await-or-timeout(
        IO::Socket::Async.connect('127.0.0.1', $port),
        :message<client connnection>,
    );
    # note "# connected  $*THREAD.id()";
    $conn.Supply(:bin);
}

multi method setup-reader('file', :$test-file, :$size --> Supply:D) {
    self.file-reader($test-file, :$size);
}

multi method setup-reader('socket', :$test-file, :$size --> Supply:D) {
    self.socket-reader($test-file, :$size);
}

constant @chunk-sizes = 1, 3, 11, 101, 1009;

method run-tests(:$reader = 'file') is export {
    unless @!tests {
        flunk "no tests!";
        return;
    }

    for @!tests -> %test {

        # Run the tests at various chunk sizes
        for @chunk-sizes -> $chunk-size {
            # note "chunk size $chunk-size";
            my $test-file = "t/data/%test<source>".IO;
            my $gots = self.test-class.parse-http(
                self.setup-reader($reader, :$test-file, :size($chunk-size)),
                :$!debug,
            );

            my @expected := %test<expected>;
            my %quits    = %test<quits> // %();

            self.run-test($gots, @expected, :%quits);

            CATCH {
                default {
                    .note;
                    flunk "Because: " ~ $_;
                }
            }
        }
    }
}
