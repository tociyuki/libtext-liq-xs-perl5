package Text::Liq::XS;
use 5.008002;
use strict;
use warnings;
use Carp;
use English qw(-no_match_vars);
use Scalar::Util qw(looks_like_number);
use integer;

our $VERSION = '0.01';

require XSLoader;
XSLoader::load('Text::Liq::XS', $VERSION);

my $STACK_LIMIT = 50;

my(# template symbols
    $EOF, $PLAIN, $CONST, $STRING, $NUMBER, $ESCAPE, $NOESCAPE,
    $ASSIGN, $CAPTURE, $DECREMENT, $INCREMENT, $INCLUDE, $CASE,
    $FOR, $IF, $UNLESS, $ELSE, $IFCHANGED, $CYCLE, $FILTER,
    $OR, $AND, $NOT, $RANGE, $REVERSED, $BREAK, $CONTINUE,
    $EQ, $NE, $LT, $LE, $GT, $GE, $CONTAINS, $VARIABLE, $BEGIN,
) = (1 .. 36);
my $ERROR = 53;

sub parse {
    my($class, $source) = @_;
    my $token_list = xtokenize($source);
    if ($token_list->[0][0] == $ERROR) {
        _error($source, $token_list->[0][2]);
    }
    my $template = xparse($source, $token_list);
    if ($token_list->[0][0] == $ERROR) {
        _error($source, $token_list->[0][2]);
    }
    return $template;
}

sub _error {
    my($source, $i) = @_;
    my $lft = substr $source, 0, $i;
    my $rgt = substr $source, $i;
    my $n = 1 + ($lft =~ tr/\n/\n/);
    my $j = rindex $lft, "\n";
    if (0 <= $j) {
        $lft = substr $lft, $j + 1;
    }
    my $k = index $rgt, "\n";
    if (0 <= $k) {
        $rgt = substr $rgt, 0, $k;
    }
    die qq(SyntaxError: line $n '$lft' ?'$rgt'.\n);
}

sub render {
    my($class, $template, $var, %resources) = @_;
    my $filters = $resources{'filter'} || {};
    my $dir = $resources{'directory'};
    my $string = q();
    my $env = [[{'ifchanged' => q()}, $var || {}, {}]];
    _eval_block(\$string, $template, $env, $filters, $dir);
    return $string;
}

my %XML_SPECIAL = (
    q(&) => '&amp;', q(<) => '&lt;', q(>) => '&gt;', q(") => '&quot;',
    q(') => '&#39;', q(\\) => '&#92;',
);

my @EVAL_BLOCK;
$EVAL_BLOCK[$NOESCAPE] = \&_eval_noescape;
$EVAL_BLOCK[$FOR] = \&_eval_for;
$EVAL_BLOCK[$BREAK] = \&_eval_break;
$EVAL_BLOCK[$CONTINUE] = \&_eval_continue;
$EVAL_BLOCK[$CASE] = \&_eval_case;
$EVAL_BLOCK[$CAPTURE] = \&_eval_capture;
$EVAL_BLOCK[$CYCLE] = \&_eval_cycle;
$EVAL_BLOCK[$IFCHANGED] = \&_eval_ifchanged;
$EVAL_BLOCK[$INCLUDE] = \&_eval_include;
$EVAL_BLOCK[$ASSIGN] = \&_eval_assign;
$EVAL_BLOCK[$DECREMENT] = \&_eval_decrement;
$EVAL_BLOCK[$INCREMENT] = \&_eval_increment;

my $THROW_BREAK = __PACKAGE__ . '::ThrowBreak';
my $THROW_CONTINUE = __PACKAGE__ . '::ThrowContinue';

sub _eval_block {
    my($out, $template, $env, $filters, $dir) = @_;
    my $i = 1;
    while ($i < @{$template}) {
        my $expr = $template->[$i++];
        my $func = $expr->[0];
        if ($func == $PLAIN) {
            ${$out} .= $expr->[1];
            next;
        }
        elsif ($func == $ESCAPE) {
            my $s = _eval_value_pipeline($expr, 1, $env, $filters);
            $s = defined $s ? $s : q();
            $s =~ s/([&<>"'\\])/$XML_SPECIAL{$1}/egmsx;
            ${$out} .= $s;
            next;
        }
        elsif ($func == $IF) {
            my $j = 1;
            while ($j < @{$expr}) {
                my $clause = $expr->[$j++];
                if (ref $clause->[0]) {
                    my $c = _eval_expression($clause->[0], $env);
                    next if ! $c;
                }
                _eval_block($out, $clause, $env, $filters, $dir);
                last;
            }
            next;
        }
        $EVAL_BLOCK[$func]->($out, $expr, $env, $filters, $dir);
    }
    return;
}

sub _eval_noescape {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $s = _eval_value_pipeline($expr, 1, $env, $filters);
    $s = defined $s ? $s : q();
    ${$out} .= $s;
    return;
}

sub _eval_for {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $scope = $env->[-1];
    my $for = $expr->[1][0];
    my $list = $for->[1];
    if ($list->[0] == $RANGE) {
        my $from = _eval_value($list->[1], $env);
        my $to = _eval_value($list->[2], $env);
        $list = [$from .. $to];
    }
    else {
        $list = _eval_value($list, $env);
    }
    $list = ! defined $list ? []
           : ! ref $list && $list eq q() ? [] # Liquid way
           : ref $list eq 'HASH' ? [sort keys %{$list}]
           : ref $list ne 'ARRAY' ? [$list]
           : $list;
    my @array = @{$list};
    my $offset = $for->[2];
    my $limit = _eval_value($for->[3], $env);
    my $reversed = $for->[4];
    my $group = $for->[5];
    if ($offset->[0] eq $CONTINUE) {
        $offset = $scope->[0]{$group} ||= 0;
    }
    else {
        $offset = _eval_value($offset, $env);
    }
    if (! $limit) {
        $limit = @array;
    }
    if ($offset >= @array) {
        @array = ();
    }
    else {
        @array = splice @array, $offset, $limit;
    }
    $scope->[0]{$group} = $offset + (scalar @array);
    my $last_index = $#array;
    if ($last_index < 0) {
        if (exists $expr->[2]) {
            _eval_block($out, $expr->[2], $env, $filters, $dir);
        }
        return;
    }
    if ($reversed) {
        @array = reverse @array;
    }
    push @{$scope}, {$for->[0][1] => undef};
    my($ref, $reftype, $slot) = _eval_variable($for->[0], $env);
    for my $i (0 .. $#array) {
        $ref->{$slot} = $array[$i];
        $scope->[-1]{'forloop'} = {
            'index0' => $i,
            'index' => $i + 1,
            'rindex' => $last_index - $i + 1,
            'rindex0' => $last_index - $i,
            'first' => $i == 0,
            'last' => $i == $last_index,
            'length' => $last_index + 1,
        };
        if (! eval{
            _eval_block($out, $expr->[1], $env, $filters, $dir);
            1;
        }) {
            my $e = $@;
            my $reftype = ref $e;
            if ($reftype eq $THROW_BREAK) {
                last;
            }
            elsif ($reftype ne $THROW_CONTINUE) {
                pop @{$scope};
                die $e;
            }
        }
    }
    pop @{$scope};
    return;
}

sub _eval_break {
    my($out, $expr, $env, $filters, $dir) = @_;
    if (exists $env->[-1][-1]{'forloop'}) {
        die bless {}, $THROW_BREAK;
    }
    return;
}

sub _eval_continue {
    my($out, $expr, $env, $filters, $dir) = @_;
    if (exists $env->[-1][-1]{'forloop'}) {
        die bless {}, $THROW_CONTINUE;
    }
    return;
}

sub _eval_case {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $v0 = _eval_value($expr->[1][0], $env);
    if (@{$expr->[1]} > 1) {
        _eval_block($out, $expr->[1], $env, $filters, $dir);
    }
    my $j = 2;
    while ($j < @{$expr}) {
        my $clause = $expr->[$j++];
        if (ref $clause->[0]) {
            my $found;
            for my $alt (@{$clause->[0]}) {
                my $v1 = _eval_value($alt, $env);
                if (_eval_eq($v0, $v1)) {
                    $found = 1;
                    last;
                }
            }
            next if ! $found;
        }
        _eval_block($out, $clause, $env, $filters, $dir);
        last;
    }
    return;
}

sub _eval_cycle {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $group = $expr->[1];
    if (! exists $env->[-1][0]{$group}) {
        $env->[-1][0]{$group} = 2;
    }
    ${$out} .= $expr->[ $env->[-1][0]{$group} ];
    ++$env->[-1][0]{$group};
    if ($env->[-1][0]{$group} > $#{$expr}) {
        $env->[-1][0]{$group} = 2;
    }
    return;
}

sub _eval_ifchanged {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $cap = q();
    _eval_block(\$cap, $expr, $env, $filters, $dir);
    return if $cap eq $env->[-1][0]{'ifchanged'};
    ${$out} .= $cap;
    $env->[-1][0]{'ifchanged'} = $cap;
    return;
}

sub _eval_include {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $name = _eval_value($expr->[1], $env);
    my $forexpr = $expr->[2] || [$VARIABLE, $name];
    my $param = $expr->[3];
    my $argexpr = $expr->[4];
    my $subexpr = $dir->get_template_code($name, $env) or return;
    if (@{$env} > $STACK_LIMIT) {
        croak 'StackFull: stack over.';
    }
    my $for_value = _eval_value($forexpr, $env);
    $for_value = ref $for_value eq 'ARRAY' ? $for_value : [$for_value];
    my @args = map { _eval_value($_, $env) } @{$argexpr};
    for my $name_value (@{$for_value}) {
        push @{$env}, [{'ifchanged' => q()}, {}];
        for my $i (0 .. $#{$param}) {
            my($ref, $reftype, $slot) = _eval_variable($param->[$i], $env);
            $ref->{$slot} = $args[$i];
        }
        $env->[-1][-1]{$name} = $name_value;
        _eval_block($out, $subexpr, $env, $filters, $dir);
        pop @{$env};
    }
    return;
}

sub _eval_assign {
    my($out, $expr, $env, $filters, $dir) = @_;
    my($ref, $reftype, $slot) = _eval_variable($expr->[1], $env);
    my $value = _eval_value_pipeline($expr, 2, $env, $filters);
    if ($reftype eq 'HASH') {
        $ref->{$slot} = $value;
    }
    elsif ($reftype eq 'ARRAY') {
        $ref->[$slot] = $value;
    }
    elsif (eval { $ref->can($slot) }) {
        $ref->$slot($value);
    }
    return;
}

sub _eval_capture {
    my($out, $expr, $env, $filters, $dir) = @_;
    my $buffer = q();
    _eval_block(\$buffer, $expr->[1], $env, $filters, $dir);
    my $head = $expr->[1][0];
    my $i = 1;
    while ($i < @{$head}) {
        $buffer = _eval_filter($buffer, $head->[$i++], $env, $filters);
    }
    my($ref, $reftype, $slot) = _eval_variable($head->[0], $env);
    if ($reftype eq 'HASH') {
        $ref->{$slot} = $buffer;
    }
    elsif ($reftype eq 'ARRAY') {
        $ref->[$slot] = $buffer;
    }
    elsif (eval { $ref->can($slot) }) {
        $ref->$slot($buffer);
    }
    return;
}

sub _eval_decrement {
    my($out, $expr, $env, $filters, $dir) = @_;
    my($ref, $reftype, $slot) = _eval_variable($expr->[1], $env);
    if ($reftype eq 'HASH') {
        $ref->{$slot} = ! defined $ref->{$slot} ? 0
            : looks_like_number("$ref->{$slot}") ? $ref->{$slot}
            : 0;
        ${$out} .= --$ref->{$slot};
    }
    elsif ($reftype eq 'ARRAY') {
        $ref->[$slot] = ! defined $ref->[$slot] ? 0
            : looks_like_number("$ref->[$slot]") ? $ref->[$slot]
            : 0;
        ${$out} .= --$ref->[$slot];
    }
    return;
}

sub _eval_increment {
    my($out, $expr, $env, $filters, $dir) = @_;
    my($ref, $reftype, $slot) = _eval_variable($expr->[1], $env);
    if ($reftype eq 'HASH') {
        my $v = $ref->{$slot} = ! defined $ref->{$slot} ? 0
            : looks_like_number("$ref->{$slot}") ? $ref->{$slot}
            : 0;
        ${$out} .= $v;
        ++$ref->{$slot};
    }
    elsif ($reftype eq 'ARRAY') {
        my $v = $ref->[$slot] = ! defined $ref->[$slot] ? 0
            : looks_like_number("$ref->[$slot]") ? $ref->[$slot]
            : 0;
        ${$out} .= $v;
        ++$ref->[$slot];
    }
    return;
}

sub _eval_value_pipeline {
    my($expr, $i, $env, $filters) = @_;
    my $s = _eval_value($expr->[$i++], $env);
    while ($i < @{$expr}) {
        $s = _eval_filter($s, $expr->[$i++], $env, $filters);
    }
    return $s;
}

sub _eval_contains {
    my($lhs, $rhs) = @_;
    my $found = q();
    if (! ref $lhs) {
        $found = 0 <= index $lhs, $rhs;
    }
    elsif (ref $lhs eq 'HASH') {
        $found = exists $lhs->{$rhs};
    }
    elsif (ref $lhs eq 'ARRAY') {
        for (@{$lhs}) {
            next if $_ ne $rhs;
            $found = 1;
            last;
        }
    }
    return $found;
}

sub _eval_value {
    my($expr, $env) = @_;
    # $env = [.., [$stash, $frame0, $frame1, ..]];
    my $type = $expr->[0];
    return $expr->[1] if $type != $VARIABLE;
    my $value = undef;
    my $i = 1;
    my $slot = $expr->[$i++];
    my $scope = $env->[-1];
    my $k = $#{$scope};
    while ($k > 0) {
        if (exists $scope->[$k]{$slot}) {
            $value = $scope->[$k]{$slot};
            last;
        }
        --$k;
    }
    return $value if ! defined $value;
    my $reftype = ref $value;
    while ($i < @{$expr}) {
        my $slot = $expr->[$i++];
        if (! ref $slot) {
            if ($reftype eq 'HASH') {
                $value
                    = exists $value->{$slot} ? $value->{$slot}
                    : $slot eq 'size' ? (scalar keys %{$value})
                    : $slot eq 'empty?' ? 0 == (scalar keys %{$value})
                    : undef;
            }
            elsif ($reftype eq 'ARRAY') {
                $value
                    = $slot eq 'size' ? (scalar @{$value})
                    : $slot eq 'empty?' ? 0 == (scalar @{$value})
                    : $slot eq 'first' ? $value->[0]
                    : $slot eq 'last' ? $value->[-1]
                    : undef;
            }
            elsif (! $reftype) {
                $value
                    = $slot eq 'size' ? length $value
                    : $slot eq 'length' ? length $value
                    : $slot eq 'empty?' ? 0 == length $value
                    : undef;
            }
            else {
                $value = eval { $value->can($slot) } ? $value->$slot : undef;
            }
        }
        else {
            $slot = _eval_value($slot, $env);
            if ($reftype eq 'HASH') {
                $value = $value->{$slot};
            }
            elsif ($reftype eq 'ARRAY') {
                $value = $value->[$slot];
            }
            else {
                $value = undef;
            }
        }
        return $value if ! defined $value;
        $reftype = ref $value;
    }
    return $value;
}

sub _eval_variable {
    my($expr, $env) = @_;
    my $i = 1;
    my $slot = $expr->[$i++];
    my $scope = $env->[-1];
    my $ref = $scope->[-1];
    my $k = $#{$scope};
    while ($k > 0) {
        if (exists $scope->[$k]{$slot}) {
            $ref = $scope->[$k];
            last;
        }
        --$k;
    }
    my $reftype = ref $ref;
    while ($i < @{$expr}) {
        my $slot1 = $slot;
        $slot = $expr->[$i++];
        if (! ref $slot1) {
            if ($reftype eq 'HASH') {
                if (! exists $ref->{$slot1} || ref $ref->{$slot1} ne 'HASH') {
                    $ref->{$slot1} = {};
                }
                $ref = $ref->{$slot1};
            }
            else {
                $ref = eval { $ref->can($slot1) } ? $ref->$slot1 : undef;
            }
        }
        else {
            $slot1 = _eval_value($slot1, $env);
            if ($reftype eq 'HASH') {
                if (! exists $ref->{$slot1} || ref $ref->{$slot1} ne 'HASH') {
                    $ref->{$slot1} = {};
                }
                $ref = $ref->{$slot1};
            }
            elsif ($reftype eq 'ARRAY') {
                if (! exists $ref->[$slot1] || ref $ref->[$slot1] ne 'ARRAY') {
                    $ref->[$slot1] = {};
                }
                $ref = $ref->[$slot1];
            }
            else {
                $ref = undef;
            }
        }
        $reftype = ref $ref;
        last if ! defined $ref;
    }
    if (ref $slot) {
        $slot = _eval_value($slot, $env);
    }
    return ($ref, $reftype, $slot);
}

my @EVAL_EXPRESSION;
$EVAL_EXPRESSION[$EQ-$EQ] = \&_eval_eq;
$EVAL_EXPRESSION[$NE-$EQ] = \&_eval_ne;
$EVAL_EXPRESSION[$LT-$EQ] = \&_eval_lt;
$EVAL_EXPRESSION[$LE-$EQ] = \&_eval_le;
$EVAL_EXPRESSION[$GT-$EQ] = \&_eval_gt;
$EVAL_EXPRESSION[$GE-$EQ] = \&_eval_ge;
$EVAL_EXPRESSION[$CONTAINS-$EQ] = \&_eval_contains;

sub _eval_expression {
    my($expr, $env) = @_;
    my $func = $expr->[0];
    return $expr->[1] if $func <= $NUMBER;
    return _eval_value($expr, $env) if $func == $VARIABLE;
    my $lhs = _eval_expression($expr->[1], $env);
    if ($func == $OR) {
        return $lhs || _eval_expression($expr->[2], $env);
    }
    elsif ($func == $AND) {
        return $lhs && _eval_expression($expr->[2], $env);
    }
    return ! $lhs if $func == $NOT;
    my $rhs = _eval_expression($expr->[2], $env);
    return $EVAL_EXPRESSION[$func-$EQ]->($lhs, $rhs);
}

sub _eval_eq { return _eval_compare(@_) == 0 }
sub _eval_ne { return _eval_compare(@_) != 0 }
sub _eval_lt { return _eval_compare(@_) == -1 }
sub _eval_gt { return _eval_compare(@_) >  0 }
sub _eval_ge { return _eval_compare(@_) >= 0 }

sub _eval_le {
    my $i = _eval_compare(@_);
    return $i == -1 || $i == 0;
}

no integer;

sub _eval_compare {
    my($lhs, $rhs) = @_;
    return ! defined $lhs && ! defined $rhs ? 0
        : ! defined $lhs || ! defined $rhs ? -2
        : ref $lhs eq 'ARRAY' && ref $rhs eq 'ARRAY'
             && @{$lhs} == 0 && @{$rhs} == 0 ? 0
        : looks_like_number("$lhs") && looks_like_number("$rhs")
        ? ($lhs <=> $rhs) : ($lhs cmp $rhs);    
}

my %STDFILTER = (
    'escape' => \&_filter_escape,
    'h' => \&_filter_escape,
    'escape_once' => \&_filter_escape_once,
    'downcase' => \&_filter_downcase,
    'upcase' => \&_filter_upcase,
    'first' => \&_filter_first,
    'last' => \&_filter_last,
    'sort' => \&_filter_sort,
    'nsort' => \&_filter_nsort,
    'map' => \&_filter_map,
    'size' => \&_filter_size,
    'prepend' => \&_filter_prepend,
    'append' => \&_filter_append,
    'minus' => \&_filter_minus,
    'plus' => \&_filter_plus,
    'times' => \&_filter_times,
    'divided_by' => \&_filter_divided_by,
    'modulo' => \&_filter_modulo,
    'checked' => \&_filter_checked,
    'selected' => \&_filter_selected,
    'split' => \&_filter_split,
    'join' => \&_filter_join,
    'capitalize' => \&_filter_capitalize,
    'attribute' => \&_filter_attribute,
    'strip_html' => \&_filter_strip_html,
    'strip_newlines' => \&_filter_strip_newlines,
    'newline_to_br' => \&_filter_newline_to_br,
    'replace' => \&_filter_replace,
    'replace_first' => \&_filter_replace_first,
    'remove' => \&_filter_remove,
    'remove_first' => \&_filter_remove_first,
    'truncate' => \&_filter_truncate,
    'truncatewords' => \&_filter_truncatewords,
    'date' => \&_filter_date,
);

sub _eval_filter {
    my($s, $expr, $env, $filters) = @_;
    my $name = $expr->[1];
    my $proc = exists $filters->{$name} ? $filters->{$name}
              : exists $STDFILTER{$name} ? $STDFILTER{$name}
              : return " {{ filter_not_found | $name }} ";
    my @arg;
    my $i = 2;
    while ($i < @{$expr}) {
        my $x = _eval_value($expr->[$i++], $env);
        push @arg, $x;
    }
    return $proc->($s, @arg);
}

my %CHECKED = map { $_ => 1 } qw(
    compact nowrap ismap declare noshade checked
    disabled readonly multiple selected noresize defer
);

sub _filter_escape {
    my($s) = @_;
    $s =~ s/([&<>"'\\])/$XML_SPECIAL{$1}/egmsx;
    return $s;
}

sub _filter_escape_once {
    my($s) = @_;
    $s =~ s{
       ([<>"'\\])
    |   &((?:\#(?:x[0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]*);)?
    }{
        $1 ? $XML_SPECIAL{$1} : $2 ? "&$2" : '&amp;'
    }egmsx;
    return $s;
}

sub _filter_downcase { return lc $_[0] }
sub _filter_upcase { return uc $_[0] }
sub _filter_first { return $_[0]->[0] }
sub _filter_last { return $_[0]->[-1] }
sub _filter_sort { return [sort @{$_[0]}] }
sub _filter_nsort { return [sort { $a <=> $b } @{$_[0]}] }
sub _filter_map { return [map { $_->{$_[1]} } @{$_[0]}] }
sub _filter_size { return ! ref $_[0] ? length $_[0] : $#{$_[0]} + 1 }
sub _filter_prepend { return $_[1] . $_[0] }
sub _filter_append { return $_[0] . $_[1] }
sub _filter_minus { return $_[0] - $_[1] }
sub _filter_plus { return $_[0] + $_[1] }
sub _filter_times { return $_[0] * $_[1] }
sub _filter_divided_by { return int $_[0] / $_[1] }
sub _filter_modulo { return $_[0] % $_[1] }
sub _filter_checked { return _filter_attribute($_[0], 'checked') }
sub _filter_selected { return _filter_attribute($_[0], 'selected') }

sub _filter_split {
    my($s, $f) = @_;
    $f = quotemeta $f;
    return [split /$f/msx, $s, -1];
}

sub _filter_join {
    my($a, $f) = @_;
    $f = ! defined $f ? q( ) : $f;
    return join $f, @{$a};
}

sub _filter_capitalize {
    my($s) = @_;
    $s =~ s{(\w+)}{ ucfirst $1 }egmsx;
    return $s;
}

sub _filter_attribute {
    my($v, $k) = @_;
    my @attr;
    if (ref $v eq 'ARRAY') {
        $v = join q( ), @{$v};
    }
    if ($CHECKED{$k}) {
        if ($v && 'false' ne lc $v) {
            push @attr, $k . q(=") . $k . q(");
        }
    }
    else {
        if ($k eq 'href' || $k eq 'src' || 0 <= index $k, 'resource') {
            if (utf8::is_utf8($v)) {
                require Encode;
                $v = Encode::encode_utf8($v);
            }
            $v =~ s{(%[[:xdigit:]]{2})|([^\w\-=/,.:;?\#\$\&])}{
                $1 ? $1 : sprintf '%%%02X', ord $2
            }egmsx;
        }
        $v = $k eq 'value' ? _filter_escape($v) : _filter_escape_once($v);
        push @attr, _filter_escape_once($k) . q(=") . $v . q(");
    }
    return join q(), @attr;
}

sub _filter_strip_html {
    my($s) = @_;
    $s =~ s{<(?:script.*?</script|style.*?</style)?[^>]*>}{}gimsx;
    return $s;
}

sub _filter_strip_newlines {
    my($s) = @_;
    $s =~ s{(?:\r\n?|\n)+}{}gmsx;
    return $s;
}

sub _filter_newline_to_br {
    my($s) = @_;
    $s =~ s{(\r\n?|\n)}{<br />$1}gmsx;
    return $s;
}

sub _filter_replace {
    my($s, $f, $t) = @_;
    $f = quotemeta $f;
    $s =~ s{$f}{$t}gmsx;
    return $s;
}

sub _filter_replace_first {
    my($s, $f, $t) = @_;
    $f = quotemeta $f;
    $s =~ s{$f}{$t}msx;
    return $s;
}

sub _filter_remove {
    my($s, $f) = @_;
    $f = quotemeta $f;
    $s =~ s{$f}{}gmsx;
    return $s;
}

sub _filter_remove_first {
    my($s, $f, $t) = @_;
    $f = quotemeta $f;
    $s =~ s{$f}{}msx;
    return $s;
}

sub _filter_truncate {
    my($s, $n) = @_;
    return $s if ! defined $n || $n >= length $s;
    return '...' if $n < 4;
    return substr ($s, 0, $n - 3) . '...';
}

sub _filter_truncatewords {
    my($s, $n) = @_;
    return $s if ! defined $n;
    return '...' if $n < 1;
    my $m = $n - 1;
    my($t) = $s =~ m/(\w+(?:\W*\w+){0,$m})/msx;
    return $s eq $t ? $s : $t . '...';
}

sub _filter_date {
    my($s, $fmt) = @_;
    $fmt = ! defined $fmt || $fmt eq q() ? '%F %T' : $fmt;
    require Encode;
    require POSIX;
    require Time::Piece;
    return undef if ! defined $s; ## no critic qw(ExplicitReturnUndef)
    my $epoch
        = ref $s && eval { $s->can('epoch') } ? $s->epoch
        : ref $s ? return $s
        : defined $s && $s eq 'now' ? time
        : undef;
    if (! defined $epoch && $s =~ m{\A\s*
        ([0-9]+)[-/]([0-9]+)[-/]([0-9]+)
        (?:(?:T|\s+)([0-9]+)[:]([0-9]+)(?:[:]([0-9]+)(?:[.][0-9]+)?)?)?
        (?:\s*(Z|UTC|GMT|[+-]00[:]?00))?
        \s*
    \z}msx) {
        my $s1 = sprintf '%04d-%02d-%02dT%02d:%02d:%02d',
            $1, $2, $3, $4 || 0, $5 ||0, $6 || 0;
        my $tpiece = defined $7 ? Time::Piece->gmtime : Time::Piece->localtime;
        $epoch = $tpiece->strptime($s1, '%Y-%m-%dT%H:%M:%S')->epoch;
    }
    elsif (! defined $epoch && looks_like_number($s)) {
        $epoch = $s;
    }
    else {
        return $s;
    }
    my $time = $fmt =~ m/Z|UTC|GMT|[+-]00[:]?00/msx
        ? Time::Piece->gmtime($epoch) : Time::Piece->localtime($epoch);
    my $is_utf8 = utf8::is_utf8($fmt);
    if ($is_utf8) {
        $fmt = Encode::encode('UTF-8', $fmt);
    }
    my $loc = POSIX::setlocale(POSIX::LC_TIME(), q());
    POSIX::setlocale(POSIX::LC_TIME(), 'C');
    my $t = $time->strftime($fmt);
    POSIX::setlocale(POSIX::LC_TIME(), $loc);
    if ($is_utf8) {
        $t = Encode::decode('UTF-8', $t);
    }
    return $t;
}

1;

__END__


=head1 NAME

Text::Liq::XS - Liquid markup template processor XSUB parser.

=head1 VERSION

0.01

=head1 SYNOPSIS

    use Text::Liq::XS;
    
    my $liquid_content = <<'EOS';
    {% for entry in entries %}
    <article id="{{ entry.id }}">
      <h1>{{ entry.title }}</h1>
      <div class="posted">{{ entry.posted | date:'%Y-%m-%d %H:%M' }}</div>
      {{{ entry.content }}}
    <article>
    {% endfor %}
    EOS
    my $template = Text::Liq::XS->parse($liquid_content);
    my $html = Text::Liq::XS->render($template, {
        'entries' => [
            {'title' => 'Liq markups',
             'posted' => '2013-03-25T22:33:44',
             'content' => '...'},
            {'title' => 'Liq markups grammary',
             'posted' => '2013-03-25T21:32:44',
             'content' => '...'},
        ],
    });

=head1 DESCRIPTION

This module provides you XSUB edition parser of Liquid markups.
Fully compatible with pure perl edition parser Text::Liq module.
Current edition has XSUB parser and XSUB tokenizer, but still
renders in pure perl.

=head1 METHODS 

=over

=item C<< Text::Liq::XS->parse($liquid_content_string) >>

Parses a given Liquid markup content and converts to a tree
in compatible with Text::Liq->parse results.

=item C<< Text::Liq::XS->render($compiled_code, \%param, %resources) >>

Runs the parsed template tree with parameters, and optional filter suits.
Optional resources take
This is just same as Text::Liq's one. It is not yet XSUB.

=head1 SEE ALSO

L<Text::Liq>

=head1 AUTHOR

MIZUTANI Tociyuki, C<< tociyuki at gmail.com >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by MIZUTANI Tociyuki

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
