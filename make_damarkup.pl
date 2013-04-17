#!/usr/bin/env perl
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);

our $VERSION = '0.01';

# builds the double array trie for Liquid markups

my @markup = qw(
    assign break capture case comment continue cycle decrement
    else elsif endcapture endcase endfor endif endifchanged
    endunless for if ifchanged include increment raw unless when
);

# double array
my @base;
my @check;
my $EOS = "\x24";
my %code = ($EOS => 1, map { $_ => (ord $_) - (ord 'a') + 2 } 'a' .. 'z');

sub any {
    my($yield, @a) = @_;
    for (@a) {
        return 1 if $yield->($_);
    }
    return;
}

sub make_array {
    my(@words) = @_;
    my @keylist = map { $_ . $EOS } sort @words;
    @base = (-1, 1);
    @check = (-1, 0);
    my @stack = (\@keylist, 0, 1);
    while (@stack) {
        my($a, $i, $parent) = splice @stack, -3;
        next if ! @{$a};
        my %h = map { (substr $_, $i, 1) => 1 } @{$a};
        my @edge = sort keys %h;
        my @edgecode = map { $code{$_} } @edge;
        my $b = 1 - $edgecode[0];
        while (any(sub{ defined $check[$b + $_] }, @edgecode)) {
            ++$b
        }
        $base[$parent] = $b;
        for my $j (@edgecode) {
            $check[$b + $j] = $parent;
        }
        my $i1 = $i + 1;
        for my $c (reverse @edge) {
            my @a1 = grep {
                $i1 < (length $_) && (substr $_, $i, 1) eq $c
            } @{$a};
            push @stack, \@a1, $i1, $b + $code{$c};
        }
    }
    return;
}

sub match_array {
    my($word) = @_;
    my $s = $word . $EOS;
    my $b = 1;
    for my $c (split //, $s) {
        my $b1 = $base[$b] + $code{$c};
        return if ! defined $check[$b1] || $check[$b1] != $b;
        $b = $b1;
    }
    return $b;
}

make_array(@markup);

for my $w (@markup) {
    my $b = match_array($w);
    $base[$b] = uc "liq_$w";
}
for (@base, @check) {
    if (looks_like_number($_)) {
        $_ = sprintf '%3d', $_;
    }
}

my @lines = (q( *    ));
my $i = 0;
for my $w (sort @markup) {
    if ((length $lines[-1]) + 3 + (length $w) < 76) {
        $lines[-1] .= ($i++ ? q( | ) : q(   )) . $w;
    }
    else {
        $lines[-1] .= "\n";
        push @lines, q( *    );
    }
}
$lines[-1] .= "\n";
my $commentlines = join q(), @lines;
my $n = @base;
print <<"EOS";
/* generated `perl make_damarkup.pl` */
/* Double Array Trie of markups
 *
$commentlines *
 */
#define LIQ_TRIE_MARKUP_SIZE     $n

static IV liq_markup_base[LIQ_TRIE_MARKUP_SIZE] = {
EOS
my $i = 0;
while ($i < @base) {
    my $j = $i + 9 < $#base ? $i + 9 : $#base;
    print q(    ), (join q(, ), @base[$i .. $j]), ",\n";
    $i += 10;
}
print <<'EOS';
};
static IV liq_markup_check[LIQ_TRIE_MARKUP_SIZE] = {
EOS
$i = 0;
while ($i < @check) {
    my $j = $i + 9 < $#check ? $i + 9 : $#check;
    print q(    ), (join q(, ), @check[$i .. $j]), ",\n";
    $i += 10;
}
print <<'EOS';
};
EOS

__END__

=pod

=head1 NAME

make_damarkup.pl - Liquid markup double array trie table generator.

=head1 VERSION

0.01

=head1 SYNOPSIS

    # in your editor vi
    :r! perl make_damarkup.pl

=head1 DESCRIPTION

This script provides you to generate Liquid markup double array trie
table that is used Text-Liq-XS/XS.xs's tokenize subroutine state 4.

=head1 FUNCTIONS 

=over

=item C<< any(sub{ defined $check[$b + $_] }, @edgecode) >>

Just same as List::Utils::any.

=item C<< make_array(@word_list) >>

Makes double array contents C<@base> and C<@check> from C<@word_list>.

=item C<< match_array($word) >>

Test if C<$word> matchs double array trie.
On success, it returns index number of C<@base> array.
On failure, it returns C<undef>. 

=head1 SEE ALSO

L<http://linux.thai.net/~thep/datrie/>

=head1 AUTHOR

MIZUTANI Tociyuki, C<< tociyuki at gmail.com >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by MIZUTANI Tociyuki

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.1 or,
at your option, any later version of Perl 5 you may have available.

=cut

