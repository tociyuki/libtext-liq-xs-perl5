use strict;
use warnings;
use Text::Liq::XS;
use Test::Base;
use Test::LeakTrace;

filters {
    'input' => [qw(chomp)],
    'expected' => [qw(chomp)],
    'param' => [qw(eval)],
};

plan tests => 1 * blocks;

run {
    my($block) = @_;
    no_leaks_ok {
        my $liq = Text::Liq::XS->parse($block->input);
        my $got = Text::Liq::XS->render($liq, $block->param);
    };
};

__END__

=== unliq statement
--- input
this text should come out of the template without change...
--- param
+{}
--- expected
this text should come out of the template without change...

=== comment
--- input
the comment block should be removed {%comment%} be gone.. {%endcomment%} .. right?
--- param
+{}
--- expected
the comment block should be removed  .. right?

=== assign
--- input
<tt>var2:{{var2}} {%assign var2 = var%} var2:{{var2}}</tt>
--- param
+{'var' => 'content'}
--- expected
<tt>var2:  var2:content</tt>

=== hyphenated assign in slot
--- input
<tt>a-b:{{var['a-b']}} {%assign var['a-b'] = 2 %}a-b:{{var['a-b']}}</tt>
--- param
+{'var' => {'a-b' => 1}}
--- expected
<tt>a-b:1 a-b:2</tt>

=== capture
--- input
<tt>{{ var2 }}{% capture var2 %}{{ var }} foo {% endcapture %}{{ var2 }}{{ var2 }}</tt>
--- param
+{'var' => 'content'}
--- expected
<tt>content foo content foo </tt>

=== case condition 2
--- input
<tt>{% case condition %}{% when 1 %} its 1 {% when 2 %} its 2 {% endcase %}</tt>
--- param
+{'condition' => 2}
--- expected
<tt> its 2 </tt>

=== case condition 'string here'
--- input
<tt>{% case condition %}{% when "string here" %} hit {% endcase %}</tt>
--- param
+{'condition' => 'string here'}
--- expected
<tt> hit </tt>

=== case on size 0
--- input
<tt>{% case a.size %}{% when 1 %}1{% when 2 %}2{% endcase %}</tt>
--- param
+{'a' => []}
--- expected
<tt></tt>

=== case on empty
--- input
<tt>{% case a.empty? %}{% when true %}true{% when false %}false{% else %}else{% endcase %}</tt>
--- param
+{'a' => []}
--- expected
<tt>true</tt>

=== case on false
--- input
<tt>{% case false %}{% when true %}true{% when false %}false{% else %}else{% endcase %}</tt>
--- param
+{'a' => []}
--- expected
<tt>false</tt>

=== case on true
--- input
<tt>{% case true %}{% when true %}true{% when false %}false{% else %}else{% endcase %}</tt>
--- param
+{'a' => []}
--- expected
<tt>true</tt>

=== case on null
--- input
<tt>{% case null %}{% when true %}true{% when false %}false{% else %}else{% endcase %}</tt>
--- param
+{'a' => []}
--- expected
<tt>else</tt>

=== case shopify 1
--- input
{% case collection.handle %}
{% when 'menswear-jackets' %}
{%   assign ptitle = 'menswear' %}
{% when 'menswear-t-shirts' %}
{%   assign ptitle = 'menswear' %}
{% else %}
{%   assign ptitle = 'womenswear' %}
{% endcase %}
<tt>{{ ptitle }}</tt>
--- param
+{'collection' => {'handle' => 'menswear-jackets'}}
--- expected
<tt>menswear</tt>

=== case when or 1
--- input
<tt>{% case condition %}{% when 1 or 2 or 3 %} its 1 or 2 or 3 {% when 4 %} its 4 {% endcase %}</tt>
--- param
+{'condition' => 1}
--- expected
<tt> its 1 or 2 or 3 </tt>

=== case when comma 1
--- input
<tt>{% case condition %}{% when 1, 2, 3 %} its 1 or 2 or 3 {% when 4 %} its 4 {% endcase %}</tt>
--- param
+{'condition' => 1}
--- expected
<tt> its 1 or 2 or 3 </tt>

=== cycle default group one
--- input
<tt>{%cycle "one", "two"%}</tt>
--- param
+{}
--- expected
<tt>one</tt>

=== cycle default group one two
--- input
<tt>{%cycle "one", "two"%} {%cycle "one", "two"%}</tt>
--- param
+{}
--- expected
<tt>one two</tt>

=== cycle default group empty two
--- input
<tt>{%cycle "", "two"%} {%cycle "", "two"%}</tt>
--- param
+{}
--- expected
<tt> two</tt>

=== cycle default group one two one
--- input
<tt>{%cycle "one", "two" %} {%cycle "one", "two" %} {%cycle "one", "two" %}</tt>
--- param
+{}
--- expected
<tt>one two one</tt>

=== cycle left right
--- input
<tt>{%cycle "text-align: left", "text-align: right" %} {%cycle "text-align: left", "text-align: right" %}</tt>
--- param
+{}
--- expected
<tt>text-align: left text-align: right</tt>

=== cycle multiple
--- input
<tt>{%cycle 1,2 %} {%cycle 1,2 %} {%cycle 1,2 %} {%cycle 1,2,3 %} {%cycle 1,2,3 %} {%cycle 1,2,3 %} {%cycle 1,2,3 %}</tt>
--- param
+{}
--- expected
<tt>1 2 1 1 2 3 1</tt>

=== cycle group multiple
--- input
<tt>{%cycle 1: "one", "two" %} {%cycle 2: "one", "two" %} {%cycle 1: "one", "two" %} {%cycle 2: "one", "two" %} {%cycle 1: "one", "two" %} {%cycle 2: "one", "two" %}</tt>
--- param
+{}
--- expected
<tt>one one two two one one</tt>

=== cycle group multiple 2
--- input
<tt>{%cycle var1: "one", "two" %} {%cycle var2: "one", "two" %} {%cycle var1: "one", "two" %} {%cycle var2: "one", "two" %} {%cycle var1: "one", "two" %} {%cycle var2: "one", "two" %}</tt>
--- param
+{'var1' => 1, 'var2' => 1}
--- expected
<tt>one one two two one one</tt>

=== size of array
--- input
<tt>array has {{ array.size }} elements</tt>
--- param
+{'array' => [1, 2, 3, 4]}
--- expected
<tt>array has 4 elements</tt>

=== size of hash
--- input
<tt>hash has {{ hash.size }} elements</tt>
--- param
+{'hash' => {'a' => 1, 'b' => 2, 'c' => 3, 'd' => 4}}
--- expected
<tt>hash has 4 elements</tt>

=== true is not empty
--- input
<tt>{% if true == empty %}?{% endif %}</tt>
--- param
+{}
--- expected
<tt></tt>

=== true is not null
--- input
<tt>{% if true == null %}?{% endif %}</tt>
--- param
+{}
--- expected
<tt></tt>

=== empty is not null
--- input
<tt>{% if empty == null %}?{% endif %}</tt>
--- param
+{}
--- expected
<tt></tt>

=== ifchanged 1 1 2 2 3 3
--- input
<tt>{%for item in array%}{%ifchanged%}{{item}}{% endifchanged %}{%endfor%}</tt>
--- param
+{'array' => [1, 1, 2, 2, 3, 3]}
--- expected
<tt>123</tt>

=== ifchanged 1 1 1 1
--- input
<tt>{%for item in array%}{%ifchanged%}{{item}}{% endifchanged %}{%endfor%}</tt>
--- param
+{'array' => [1, 1, 1, 1]}
--- expected
<tt>1</tt>

=== yo  yo  yo  yo
--- input
<tt>{%for item in array%} yo {%endfor%}</tt>
--- param
+{'array' => [1,2,3,4]}
--- expected
<tt> yo  yo  yo  yo </tt>

=== reversed
--- input
<tt>{%for item in array reversed%}{{item}}{%endfor%}</tt>
--- param
+{'array' => [1, 2, 3]}
--- expected
<tt>321</tt>

=== range
--- input
<tt>{%for item in (1..3) %} {{item}} {%endfor%}</tt>
--- param
+{}
--- expected
<tt> 1  2  3 </tt>

=== forloop.index/forloop.length
--- input
<tt>{%for item in array%} {{forloop.index}}/{{forloop.length}} {%endfor%}</tt>
--- param
+{'array' => ['a', 'b', 'c']}
--- expected
<tt> 1/3  2/3  3/3 </tt>

=== for limit:2
--- input
<tt>{%for i in array limit:2 %}{{ i }}{%endfor%}</tt>
--- param
+{'array' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]}
--- expected
<tt>12</tt>

=== for limit:4 offset:2
--- input
<tt>{%for i in array limit:4 offset:2 %}{{ i }}{%endfor%}</tt>
--- param
+{'array' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]}
--- expected
<tt>3456</tt>

=== for limit: var offset: var
--- input
<tt>{%for i in array limit:limit offset:offset %}{{ i }}{%endfor%}</tt>
--- param
+{
    'array' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
    'limit' => 4,
    'offset' => 2,
}
--- expected
<tt>3456</tt>

=== for in for
--- input
<tt>{%for item in array%}{%for i in item%}{{ i }}{%endfor%}{%endfor%}</tt>
--- param
+{'array' => [[1,2],[3,4],[5,6]]}
--- expected
<tt>123456</tt>

=== for offset:continue
--- input
<pre>
{%for i in array.items limit:3 %}
{{i}}
{%endfor%}
next
{%for i in array.items offset:continue limit:3 %}
{{i}}
{%endfor%}
next
{%for i in array.items offset:continue limit:3 %}
{{i}}
{%endfor%}
</pre>
--- param
+{'array' => {'items' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]}}
--- expected
<pre>
1
2
3
next
4
5
6
next
7
8
9
</pre>

=== for break
--- input
<tt>{%for i in array.items %}{% break %}{%endfor%}</tt>
--- param
+{'array' => {'items' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}}
--- expected
<tt></tt>

=== for continue
--- input
<tt>{% for i in array.items %}{% continue %}{% endfor %}</tt>
--- param
+{'array' => {'items' => [1,2,3,4,5]}}
--- expected
<tt></tt>

=== if false or false or true end
--- input
<tt>{% if a or b or c %} THEN {% endif %}</tt>
--- param
+{'a' => 1!=1, 'b' => 1!=1, 'c' => 1==1}
--- expected
<tt> THEN </tt>

=== if a == false or b == false end
--- input
<tt>{% if a == 'and'
      and b == 'or'
      and c == 'foo and bar'
      and d == 'bar or baz'
      and e == 'foo'
      and foo
      and bar %} THEN {% endif %}</tt>
--- param
+{
    'a' => 'and',
    'b' => 'or',
    'c' => 'foo and bar',
    'd' => 'bar or baz',
    'e' => 'foo',
    'foo' => 1==1,
    'bar' => 1==1,
}
--- expected
<tt> THEN </tt>

=== markup
--- input
<tt>{% raw %}{% comment %} test {% endcomment %}{% endraw %}</tt>
--- param
+{}
--- expected
<tt>{% comment %} test {% endcomment %}</tt>

=== markup escape
--- input
<tt>{% raw %}{{ test }}{% endraw %}</tt>
--- param
+{}
--- expected
<tt>{{ test }}</tt>

=== for unless end end
--- input
<tt>{% for i in choices %}{% unless i %}{{ forloop.index }}{% endunless %}{% endfor %}</tt>
--- param
+{'choices' => [1, undef, 1!=1]}
--- expected
<tt>23</tt>

=== increment decrement mix
--- input
<tt>{%increment port %} {%increment starboard%} {%increment port %} {%decrement port%} {%decrement starboard %}</tt>
--- param
+{'port' => 1, 'starboard' => 5}
--- expected
<tt>1 5 2 2 5</tt>


