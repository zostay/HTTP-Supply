use v6;

use Test;
use HTTP::Supply::Response;

use lib 't/lib';
use HTTP::Supply::Response::Test;

my @tests =
   %(
        source   => 'http-response-basic.txt',
        expected => ([
            200,
            [
                '::server-protocol'      => 'HTTP/1.1',
                '::server-reason-phrase' => 'OK',
                content-type             => 'text/plain',
                content-length           => '14',
            ],
            "Hello World!\r\n",
        ],),
    ),
;

my $tester = HTTP::Supply::Response::Test.new(:@tests);

$tester.run-tests(:reader<file>);
$tester.run-tests(:reader<socket>);

done-testing;
