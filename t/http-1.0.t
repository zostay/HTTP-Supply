#!smackup
use v6;

use Test;
use HTTP1::StreamParser;

my @chunk-sizes = 1, 3, 11, 101, 1009;

plan @chunk-sizes * 4;

# Run the tests at various chunk sizes
for @chunk-sizes -> $chunk-size {
    warn "# chunk-size $chunk-size"; # WTF? Why does this line make this test pass?
    my $test1 = 't/data/http-1.0-close.txt'.IO;
    my $envs = parse-http1-request($test1.open(:r).Supply(:size($chunk-size), :bin));

    my @expected = {
        REQUEST_METHOD     => 'POST',
        REQUEST_URI        => '/index.html',
        SERVER_PROTOCOL    => 'HTTP/1.0',
        CONTENT_TYPE       => 'application/x-www-form-urlencoded; charset=utf8',
        CONTENT_LENGTH     => '11',
        HTTP_AUTHORIZATION => 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
        HTTP_REFERER       => 'http://example.com/awesome.html',
        HTTP_CONNECTION    => 'close',
        HTTP_USER_AGENT    => 'Mozilla/Inf',
        'p6w.input'        => 'a=1&b=2&c=3',
    },;

    react {
        whenever $envs -> %env {
            my %exp = @expected.shift;

            flunk 'unexpected environment received: ', %env.perl
                unless %exp.defined;

            my $input   = %env<p6w.input> :delete;
            my $content = %exp<p6w.input> :delete;
    
            is-deeply %env, %exp, 'environment looks good';
    
            ok $input.defined, 'input found in environment';
    
            my $acc = buf8.new;
            react {
                whenever $input -> $chunk {
                    $acc ~= $chunk;
                }
                $input.wait;

                CATCH {
                    default { 
                        warn $_;
                        flunk $_;
                    }
                }
            }

            is $acc.decode('utf8'), $content, 'message body looks good';

            LAST {
                is @expected.elems, 0, 'no more tests expected';
            }

            QUIT {
                warn $_;
                flunk $_;
            }
        }
    }

    CATCH {
        default { 
            warn $_;
            flunk $_;
        }
    }
}
