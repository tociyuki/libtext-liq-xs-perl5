use strict;
use warnings;
use Text::Liq::XS;
use Test::Base;

filters {
    'input' => [qw(chomp)],
    'expected' => [qw(chomp)],
    'param' => [qw(eval)],
};

plan tests => 1 * blocks;

run {
    my($block) = @_;
    my $liq = Text::Liq::XS->parse($block->input);
    my $got = Text::Liq::XS->render($liq, $block->param);
    is $got, $block->expected, $block->name;
};

__END__

=== continue without block
--- input
<tt>{% continue %}</tt>
--- param
+{'i' => 1}
--- expected
<tt></tt>

