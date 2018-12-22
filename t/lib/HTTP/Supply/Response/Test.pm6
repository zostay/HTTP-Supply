use v6;

use HTTP::Supply::Test;
unit class HTTP::Supply::Response::Test is HTTP::Supply::Test;

use Test;
use HTTP::Supply::Response;

# Test to see that:
# 1. Every header in @got is in @exp.
# 2. Every header in @exp is in @got.
# 3. Every header in @got with a given name that repeats multiple times repeats
#    identical values in the same order in @exp.
# All key comparisons are case-insensitive. All value comparisons are
# case-sensntive.
method !headers-equivalent(@got, @exp) {
    # We use this to count which header we are looking for from @got in the
    # @exp header list. It is also used to make sure that all @exp headers are
    # seen while looking for @got matches.
    my %repeats;

    # Iterate through the got headers
    for @got -> $got {

        # If we haven't gotten this name yet, note the number of repeats as 0
        %repeats{ $got.key.fc } //= 0;

        # Counter to let us skip past repeats
        my $counter = 0;

        # Marker to let us know we found the match we were looking for.
        my $found = False;

        # Iterate through the expected headers
        for @exp -> $exp {

            # If the keys don't match, keep searching
            next unless $exp.key.fc eq $got.key.fc;

            # Found a match, but is it the nth match we want to compare with?
            next if $counter++ < %repeats{ $got.key.fc };

            # Matches name and count, do the comparison
            is $got.value, $exp.value, "$got.key() value matches";

            # We found a match, whether it was correct or not
            $found++;

            # We need to bump the repeat counter in case this column comes
            # up again.
            %repeats{ $got.key.fc }++;
        }

        # We didn't find a @got header in @exp?
        flunk "got unexpected header $got.key()"
            unless $found;
    }

    # Iterate through expected again and make sure the number of repeats
    # exactly matches the expected number to make sure every expected
    # header was found in got.
    for @exp».key -> $exp-key {
        my $got-count = %repeats{ $exp-key.fc };
        my $exp-count = +@exp.grep({ .key.fc eq $exp-key });

        is $got-count, $exp-count, "$exp-key header expected $exp-count times and seen $got-count times";
    }
}

method run-test($resps, @expected is copy, :%quits) {
    my @processing-resps;

    # capture test results in closures for later final evaluation
    my @output;
    react {
        whenever $resps -> @res {
            my @exp := try { @expected.shift } // @();

            CATCH {
                default {
                    .note; .rethrow;
                }
            }

            @output.push: {
                flunk 'unexpected response received: ', @res.perl
                    without @exp;
            };

            my $code = @res[0];
            my @headers := @res[1];
            my $output = @res[2];
            my %trailers = @res[3] // %();

            @output.push: {
                self!headers-equivalent: @headers, @exp[1];
            };

            my $acc = buf8.new;

            push @processing-resps, start {
                react {
                    whenever $output -> $chunk {
                        given $chunk {
                            when Blob { $acc ~= $chunk }
                            when Hash {
                                if $chunk eqv %trailers {
                                    @output.push: { pass 'found trailers' };
                                }
                                else {
                                    @output.push: { flunk 'found trailers' };
                                }
                                %trailers = ();
                            }
                            default {
                                @output.push: { flunk 'unknown body output' };
                            }
                        }

                        LAST {
                            @output.push: {
                                is $acc.decode('utf8'), @exp[2], 'message body looks good';
                                flunk 'trailers were not received' if %trailers;
                            };

                            done;
                        }
                    }
                }
            }

            LAST { done }

            QUIT {
                when %quits<on> {
                    @output.push: {
                        pass "Quit on expected error.";
                    }
                }
                default {
                    .note;
                    @output.push: { flunk $_ };
                }
            }
        }
    }

    self.await-or-timeout(@processing-resps, :message<processing test responses>);

    # emit test results in order, single threaded
    for @output -> $test-ok {
        $test-ok.();
    }

    is @expected.elems, 0, 'last request received, no more expected?';
}

method test-class { HTTP::Supply::Response }

