use v6;

use HTTP::Supply::Request;

unit class HTTP::Request::Supply is HTTP::Supply::Request;

method parse-http(|c) is DEPRECATED {
    self.HTTP::Supply::Request::parse-http(|c);
}
