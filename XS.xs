#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#if !defined(utf8_to_uvchr_buf)
#  define utf8_to_uvchr_buf(x,y,z) utf8_to_uvchr(x,z)
#endif

/* LIQK_TRACE 0: do nothing 1: print parser stack for debug */
#define LIQK_TRACE  0

static SV * liq_substr(SV *, IV , IV);
static SV * liq_trim_spaces(SV *);
static void liq_print_stack(AV *);
static void liq_unshift_symbols(AV *stack, IV n, ...);

/* Liquid markups grammar in LL(1) syntax */

/* Template symbols and terminal symbols and token kinds */
#define LIQ_EOF                0
#define LIQ_PLAIN              1
#define LIQ_CONST              2
#define LIQ_STRING             3
#define LIQ_NUMBER             4
#define LIQ_ESCAPE             5
#define LIQ_NOESCAPE           6
#define LIQ_ASSIGN             7
#define LIQ_CAPTURE            8
#define LIQ_DECREMENT          9
#define LIQ_INCREMENT         10
#define LIQ_INCLUDE           11
#define LIQ_CASE              12
#define LIQ_FOR               13
#define LIQ_IF                14
#define LIQ_UNLESS            15
#define LIQ_ELSE              16
#define LIQ_IFCHANGED         17
#define LIQ_CYCLE             18
#define LIQ_FILTER            19
#define LIQ_OR                20
#define LIQ_AND               21
#define LIQ_NOT               22
#define LIQ_RANGE             23
#define LIQ_REVERSED          24
#define LIQ_BREAK             25
#define LIQ_CONTINUE          26
/* Template symbols (overrap Terminal symbols) and token values */
#define LIQ_EQ                27
#define LIQ_NE                28
#define LIQ_LT                29
#define LIQ_LE                30
#define LIQ_GT                31
#define LIQ_GE                32
#define LIQ_CONTAINS          33
/* Template symbols (overrap Terminal symbols) */
#define LIQ_VARIABLE          34
#define LIQ_BEGIN             35

/* Terminal symbols and token kinds */
#define LIQ_WITH              27
#define LIQ_EQUIV             28
#define LIQ_IN                29
#define LIQ_DOT               30
#define LIQ_COLON             31
#define LIQ_COMMA             32
#define LIQ_IDENT             33
#define LIQ_CMP               34
#define LIQ_R                 35
#define LIQ_RR                36
#define LIQ_RRR               37
#define LIQ_ELSIF             38
#define LIQ_WHEN              39
#define LIQ_ENDIF             40
#define LIQ_ENDUNLESS         41
#define LIQ_ENDFOR            42
#define LIQ_ENDCASE           43
#define LIQ_ENDCAPTURE        44
#define LIQ_ENDIFCHANGED      45
#define LIQ_LPAREN            46
#define LIQ_RPAREN            47
#define LIQ_LSQUARE           48
#define LIQ_RSQUARE           49
#define LIQ_COMMENT           50
#define LIQ_RAW               51

/* The last terminal number marker for parsing dispath */
#define LIQK_TERM_LAST LIQ_RAW

/* The reporting symbol on errors */
#define LIQ_ERROR             52

/* Synthesize action symbols have corresponding C functions */
typedef void (*liq_grammar_action_t)(AV *);

#define LIQ__append           53
#define LIQ__append_break     54
#define LIQ__append_first     55
#define LIQ__append_for_slice 56
#define LIQ__append_include_arguments  57
#define LIQ__append_increment 58
#define LIQ__append_second    59
#define LIQ__append_second3   60
#define LIQ__make_if       61
#define LIQ__end_ifchanged    62
#define LIQ__end_node         63
#define LIQ__for_list_range   64
#define LIQ__ignore           65
#define LIQ__include_with     66
#define LIQ__make_assign      67
#define LIQ__make_binary      68
#define LIQ__make_capture     69
#define LIQ__make_case        70
#define LIQ__make_else        71
#define LIQ__make_elsif       72
#define LIQ__make_escape      73
#define LIQ__make_filter      74
#define LIQ__make_for         75
#define LIQ__make_ifchanged   76
#define LIQ__make_include     77
#define LIQ__make_subexpression  78
#define LIQ__make_unary       79
#define LIQ__flip_unless      80
#define LIQ__make_variable    81
#define LIQ__make_when        82
#define LIQ__set_for_reversed 83
#define LIQ__set_offset_continue 84
#define LIQ__set_offset_value 85

#define LIQK_ACTION_FIRST LIQ__append
#define LIQK_ACTION_LAST  LIQ__set_offset_value

#define LIQ__srcmark          86
#define LIQ__srcyank          87

/* Nonterminal symbols have corresponding C functions */
typedef IV (*liq_nonteminal_rule_t)(AV *, IV);

#define LIQ_block             88
#define LIQ_if_else_clause    89
#define LIQ_case_else_clause  90
#define LIQ_for_else_clause   91
#define LIQ_else_clause       92
#define LIQ_elsif_clauses     93
#define LIQ_expression        94
#define LIQ_expression1       95
#define LIQ_expression2       96
#define LIQ_expression3       97
#define LIQ_expression4       98
#define LIQ_filter_arguments  99
#define LIQ_filter_comma_arguments 100
#define LIQ_for_list         101
#define LIQ_for_offset       102
#define LIQ_for_slice        103
#define LIQ_include_arguments 104
#define LIQ_include_comma    105
#define LIQ_include_with     106
#define LIQ_pipeline         107
#define LIQ_plains           108
#define LIQ_selectors        109
#define LIQ_value            110
#define LIQ_variable         111
#define LIQ_when_clauses     112
#define LIQ_when_values      113

#define LIQK_NONTERM_FIRST LIQ_block
#define LIQK_NONTERM_LAST  LIQ_when_values

/* generated `perl make_damarkup.pl` */
/* Double Array Trie of markups
 *
 *       assign | break | capture | case | comment | continue | cycle
 *     | else | elsif | endcapture | endcase | endfor | endif
 *     | endunless | for | if | ifchanged | include | increment | raw
 *     | when
 *
 * initial state starts from 1.
 * next state s1 from s0.
 *
 *      assert(c >= 'a' && c <= 'z');
 *      s1 = liq_markup_base[s0] + c - 'a' + 2;
 *      if (liq_markup_check[s1] == s0)
 *          valid s1
 *      else
 *          undefined transition.
 *
 * for end of string (do not forget this!).
 *
 *      s1 = liq_markup_base[s0] + 1;
 *      if (liq_markup_check[s1] == s0)
 *          token_kind = liq_markup_base[s1];
 *      else
 *          undefined transition.
 */
#define LIQ_TRIE_MARKUP_SIZE     143

static IV liq_markup_base[LIQ_TRIE_MARKUP_SIZE] = {
     -1,   0, -12,  -4,  19,  46,  48,  87, -11,   1,
     99,   4,  -2,  13, LIQ_ASSIGN,  10,  15,   6,  19, 128,
    LIQ_BREAK,   6, 118,   4, 130,   5,  25,   9,  23,  29,
    LIQ_CAPTURE,  31, LIQ_CASE,  22,  20,  19,  31,  23,  18,  39,
    LIQ_COMMENT,  32,  28,  22,  40,  44,  46, LIQ_CONTINUE,  36,  44,
     50, LIQ_CYCLE,  49,  35,  49,  42,  51,  43,  38,  59,
    LIQ_DECREMENT,  42,  58,  64,  64, LIQ_ELSE,  66, LIQ_ELSIF,  59,  66,
     69,  55,  53,  67,  55,  75,  79,  59,  73,  79,
    LIQ_ENDCAPTURE,  81, LIQ_ENDCASE,  65,  84,
                LIQ_ENDFOR,  86, LIQ_ENDIF,  82,  89,
     80,  77,  85,  88,  90,  95, LIQ_ENDIFCHANGED,  85,  93,  80,
     81, 101, LIQ_ENDUNLESS,  85, 104, LIQ_FOR, 106, LIQ_IF, 107,  96,
     99, 104, 107, 110, 113, 115, LIQ_IFCHANGED, 105,  97, 115,
    115, 121, LIQ_INCLUDE, 111, 117, 120, 112, 107, 128, LIQ_INCREMENT,
    107, 131, LIQ_RAW, 121, 129, 116, 117, 137, LIQ_UNLESS, 134,
    126, 141, LIQ_WHEN
};
static IV liq_markup_check[LIQ_TRIE_MARKUP_SIZE] = {
     -1,   0,   1,   1,   1,   1,   1,   1,   2,   8,
      1,   9,  11,  12,  13,   3,  15,  16,  17,   1,
     18,   4,   1,  21,   1,  23,  21,  25,  27,  28,
     29,  26,  31,  35,  35,   4,  33,  36,  37,  38,
     39,  34,  41,  42,  43,   4,  44,  46,  45,  48,
     49,  50,   5,  52,  53,  54,  55,  56,  57,  58,
     59,   6,  61,   6,  62,  64,  68,  66,  62,  63,
     69,  70,  71,  69,  72,  71,  69,  74,  77,  78,
     79,  75,  81,  73,  83,  84,  76,  86,  69,  90,
     86,  89,  91,  92,  93,  94,  95,  88,  97,  98,
     99, 100, 101,   7, 103, 104,  10, 106, 110, 108,
    106, 109, 111, 112,  10, 113, 115, 114, 117, 118,
    119, 120, 121, 124, 117, 123, 125, 126, 127, 128,
     19, 130, 131,  22, 133, 134, 135, 136, 137,  24,
    139, 140, 141
};

/* 
 * For Liquid markups, Text-Liq-XS uses an attribute grammar
 * in LL(1) syntax. On such the class of grammars, we can parse inputs
 * running with the predictive determine pushdown automaton.
 * It is easy to implement determine automatons as a variation of CEK machine.
 * Controls of CEK machine are corresponding to the lookup tokens
 * in inputs, the environment is corresponding to the inherit and/or
 * synthesize attributes of grammars, and the continuations are
 * corresponding to the symbols in the right hand side expressions
 * of productions. 
 *
 * Nonterminal routines typically adds continuations as symbol list
 * on the stack. The continuations just are same
 * as right hand sides of production in Backus-Naur Form (BNF).
 * For example, let's look about the production for ESCAPE node.
 *
 *  block : ESCAPE value {make_escape} pipeline RR {append_first} block
 *
 * where upper cases symbols are terminals, lower cases symbols
 * are nonterminals, and braced symbols are synthesize attributes
 * respectively.
 *
 * If lookup next token is ESCAPE, we get continuations
 * from right hand side expressions. Let's use unshift/shift array
 * as the current continuations list.
 *
 *      C: (ESCAPE, @INPUTS)
 *      E: (@OUTPUTS, [@blocks])
 *      K: (block, @K)
 *
 * For nonterminal the parser calls the correspoinding rule function.
 * The rule functions unshift continuations from choosing product
 * correspoing to the lookup token at the head of control list.
 *
 *      C: (ESCAPE, @INPUTS)        # no change
 *      E: (@OUTPUTS, [@blocks])    # no change
 *      K: (ESCAPE, value, {make_escape}, pipeline, RR, {append_first}, block, @K)
 *
 * Since all of the continuations are coded as the IV type, K list is shown.
 *
 *      (LIQ_ESCAPE, LIQ_value, LIQ__make_escape, LIQ_pipeline, LIQ_RR
 *       LIQ__append_first, LIQ_block, @K)
 *
 * For empty right hand side expression of product, the continuations list
 * is not changed when the lookup token is the terminal element contained
 * the follow set of the nonterminal. In this case, the parser pushs a token
 * value on the output stack too.
 *
 * For example.
 *
 *      C: (ELSIF, @INPUTS)
 *      E: (@OUTPUTS, [@blocks])
 *      K: (block, @K)
 *
 * Since terminal ELSIF is contained in the follow set of nonterminal block:
 *
 *      FOLLOW(block) = {EOF, ELSIF, ELSE, ENDIF, ENDUNLESS, ENDCAPTURE,
 *                       ENDIFCHANGED, ENDFOR, ENDCASE, WHEN}
 *
 * we get next state.
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@blocks], ELSIF)
 *      K: (block, @K)
 */

/* LIQ_block nonterminal rules
 *
 *  block
 *    :
 *    | PLAIN {append }block
 *    | ESCAPE   value {make_escape} pipeline RR  {append_first} block
 *    | NOESCAPE value {make_escape} pipeline RRR {append_first} block
 *    | ASSIGN variable EQUIV value {make_assign}
 *      pipeline R {append_first} block
 *    | IF {make_if} expression R {append_first} block
 *      elsif_clauses if_else_clause ENDIF R {end_node} block
 *    | UNLESS {make_if} expression {flip_unless} R {append_first} block
 *      elsif_clauses if_else_clause ENDUNLESS R {end_node} block
 *    | CASE value R {make_case} plains when_clauses case_else_clause
 *      ENDCASE R {end_node} block
 *    | FOR variable IN {srcmark} for_list {srcyank} {make_for}
 *      for_slice R {append_for_slice} block for_else_clause
 *      ENDFOR R {end_node} block
 *    | CAPTURE variable {make_capture} pipeline R {append_first} block
 *      ENDCAPTURE R {end_node} block
 *    | CYCLE {append} block
 *    | DECREMENT variable R {append_increment} block
 *    | INCREMENT variable R {append_increment} block
 *    | IFCHANGED R {make_ifchanged} block
 *      ENDIFCHANGED R {end_ifchanged} block
 *    | INCLUDE value {make_include}
 *      include_with include_arguments R {append_first} block
 *    | BREAK R {append_break} block
 *    | CONTINUE R {append_break} block
 */
static
IV
liq_rule_block(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_PLAIN:
        liq_unshift_symbols(stack, 3,
            LIQ_PLAIN, LIQ__append, LIQ_block);
        break;
    case LIQ_ESCAPE:
        liq_unshift_symbols(stack, 7,
            LIQ_ESCAPE, LIQ_value, LIQ__make_escape,
            LIQ_pipeline, LIQ_RR, LIQ__append_first, LIQ_block);
        break;
    case LIQ_NOESCAPE:
        liq_unshift_symbols(stack, 7,
            LIQ_NOESCAPE, LIQ_value, LIQ__make_escape,
            LIQ_pipeline, LIQ_RRR, LIQ__append_first, LIQ_block);
        break;
    case LIQ_ASSIGN:
        liq_unshift_symbols(stack, 9,
            LIQ_ASSIGN, LIQ_variable, LIQ_EQUIV, LIQ_value, LIQ__make_assign,
            LIQ_pipeline, LIQ_R, LIQ__append_first, LIQ_block);
        break;
    case LIQ_IF:
        liq_unshift_symbols(stack, 12,
            LIQ_IF, LIQ__make_if,
            LIQ_expression, LIQ_R, LIQ__append_first, LIQ_block,
            LIQ_elsif_clauses, LIQ_if_else_clause,
            LIQ_ENDIF, LIQ_R, LIQ__end_node, LIQ_block);
        break;
    case LIQ_UNLESS:
        liq_unshift_symbols(stack, 13,
            LIQ_UNLESS, LIQ__make_if,
            LIQ_expression, LIQ__flip_unless, LIQ_R, LIQ__append_first, LIQ_block,
            LIQ_elsif_clauses, LIQ_if_else_clause,
            LIQ_ENDUNLESS, LIQ_R, LIQ__end_node, LIQ_block);
        break;
    case LIQ_CASE:
        liq_unshift_symbols(stack, 11,
            LIQ_CASE, LIQ_value, LIQ_R, LIQ__make_case, LIQ_plains,
            LIQ_when_clauses, LIQ_case_else_clause,
            LIQ_ENDCASE, LIQ_R, LIQ__end_node, LIQ_block);
        break;
    case LIQ_FOR:
        liq_unshift_symbols(stack, 16,
            LIQ_FOR, LIQ_variable, LIQ_IN,
            LIQ__srcmark, LIQ_for_list, LIQ__srcyank, LIQ__make_for,
            LIQ_for_slice, LIQ_R, LIQ__append_for_slice, LIQ_block,
            LIQ_for_else_clause,
            LIQ_ENDFOR, LIQ_R, LIQ__end_node, LIQ_block);
        break;
    case LIQ_CAPTURE:
        liq_unshift_symbols(stack, 11,
            LIQ_CAPTURE, LIQ_variable, LIQ__make_capture,
            LIQ_pipeline, LIQ_R, LIQ__append_first, LIQ_block,
            LIQ_ENDCAPTURE, LIQ_R, LIQ__end_node, LIQ_block);
        break;
    case LIQ_CYCLE:
        liq_unshift_symbols(stack, 3,
            LIQ_CYCLE, LIQ__append, LIQ_block);
        break;
    case LIQ_DECREMENT:
        liq_unshift_symbols(stack, 5,
            LIQ_DECREMENT, LIQ_variable, LIQ_R, LIQ__append_increment,
            LIQ_block);
        break;
    case LIQ_INCREMENT:
        liq_unshift_symbols(stack, 5,
            LIQ_INCREMENT, LIQ_variable, LIQ_R, LIQ__append_increment,
            LIQ_block);
        break;
    case LIQ_IFCHANGED:
        liq_unshift_symbols(stack, 8,
            LIQ_IFCHANGED, LIQ_R, LIQ__make_ifchanged, LIQ_block,
            LIQ_ENDIFCHANGED, LIQ_R, LIQ__end_ifchanged, LIQ_block);
        break;
    case LIQ_INCLUDE:
        liq_unshift_symbols(stack, 8,
            LIQ_INCLUDE, LIQ_value, LIQ__make_include,
            LIQ_include_with, LIQ_include_arguments, LIQ_R, LIQ__append_first,
            LIQ_block);
        break;
    case LIQ_BREAK:
        liq_unshift_symbols(stack, 4,
            LIQ_BREAK, LIQ_R, LIQ__append_break, LIQ_block);
        break;
    case LIQ_CONTINUE:
        liq_unshift_symbols(stack, 4,
            LIQ_CONTINUE, LIQ_R, LIQ__append_break, LIQ_block);
        break;
    case LIQ_EOF:
    case LIQ_ELSIF:
    case LIQ_ELSE:
    case LIQ_ENDIF:
    case LIQ_ENDUNLESS:
    case LIQ_ENDCAPTURE:
    case LIQ_ENDIFCHANGED:
    case LIQ_ENDFOR:
    case LIQ_ENDCASE:
    case LIQ_WHEN:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__append synthesize action
 *
 * We use only synthesize attributes in the grammar as like as
 * family of yacc(1) command.
 *
 * To synthesize the list as the tree structure, 
 * the parser stacks up token values on the output push/pop stack
 * in the order of the inputs. Synthesize actions take them.
 * After the producing processes, the actions push products
 * into the output stack for subsequent processing with other actions.
 *
 * For example, we start from any points of CEK state.
 *
 *      C: (PLAIN($plain), @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (block, @K)
 *
 * Here is the product of nonterminal block starting with terminal PLAIN.
 *
 *      block: PLAIN {append} block
 *
 * The parser changes the K list used above product.
 *
 *      C: (PLAIN($plain), @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (PLAIN, {append}, block, @K)
 *
 * For terminal, the parser pushs the value of same kind token into the stack
 * and replaces next lookup token from the inputs.
 *
 *      C: (@INPUT)
 *      E: (@OUTPUTS, [@block], $plain)
 *      K: ({append}, block, @K)
 *
 * For synthesize action, the parser calls corresponding function passing
 * the output stack. The append function changes the output stack.
 *
 *      C: (@INPUT)
 *      E: (@OUTPUTS, [@block, $plain])
 *      K: (block, @K)
 */
static
void
liq_append(AV *output)
{
    SV *plain;
    SV **item;

    plain = av_pop(output);
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), plain);
}

/* LIQ__make_escape synthesize action
 * puts new node on output stack from accepted ESCAPE or NOESCAPE token
 * and a result of value nonterminal processing.
 *
 *  block: ESCAPE   value {make_escape} pipeline RR  {append_first} block
 *  block: NOESCAPE value {make_escape} pipeline RRR {append_first} block
 *
 * example source: {{ x }} ...
 * state changes:
 *
 *      C: (ESCAPE, IDENT("x"), RR, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (ESCAPE, value, {make_escape}, pipeline, RR, {append_first}, block, @K)
 *
 *      C: (IDENT("x"), RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], ESCAPE)
 *      K: (value, {make_escape}, pipeline, RR, {append_first}, block, @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], ESCAPE, [VARIABLE, "x"])
 *      K: ({make_escape}, pipeline, RR, {append_first}, block, @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]])
 *      K: (pipeline, RR, {append_first}, block, @K)
 */
static
void
liq_make_escape(AV *output)
{
    SV *escape, *value;
    AV *node;

    value = av_pop(output);
    escape = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, escape);
    av_push(node, value);
}

/* LIQ__append_first synthesize action
 * appends new node on block node with dropping any mark symbol.
 *
 * state changes:
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]])
 *      K: (RR, {append_first}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]], RR)
 *      K: ({append_first}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, [ESCAPE, [VARIABLE, "x"]]])
 *      K: (block, @K)
 */
static
void
liq_append_first(AV *output)
{
    SV *node;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    node = av_pop(output);

    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), node);
}

/* LIQ__make_assign synthesize action
 * puts new assign node on output stack.
 *
 *  block: ASSIGN variable EQUIV value {make_assign}
 *                pipeline R {append_first} block
 *
 * example source: {% assign x = 1 %} ...
 * state changes:
 *
 *      C: (ASSIGN, IDENT("x"), EQUIV, NUMBER(1), R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (ASSIGN, variable, EQUIV, value, {make_assign}, ..., @K)
 *
 *      C: (IDENT("x"), EQUIV, NUMBER(1), R, @INPUTS)
 *      E: (@OUTPUTS, [@block], ASSIGN)
 *      K: (variable, EQUIV, value, {make_assign}, pipeline, R, ..., @K)
 *
 *      C: (EQUIV, NUMBER(1), R, @INPUTS)
 *      E: (@OUTPUTS, [@block], ASSIGN, [VARIABLE, "x"])
 *      K: (EQUIV, value, {make_assign}, pipeline, R, ..., @K)
 *
 *      C: (NUMBER(1), R, @INPUTS)
 *      E: (@OUTPUTS, [@block], ASSIGN, [VARIABLE, "x"], EQUIV)
 *      K: (value, {make_assign}, pipeline, R, {append_first}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], ASSIGN, [VARIABLE, "x"], EQUIV, [NUMBER, 1])
 *      K: ({make_assign}, pipeline, R, {append_first}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ASSIGN, [VARIABLE, "x"], [NUMBER, 1]])
 *      K: (pipeline, R, {append_first}, block, @K)
 */
static
void
liq_make_assign(AV *output)
{
    SV *tagassign, *variable, *value;
    AV *node;

    value = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    variable = av_pop(output);
    tagassign = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, tagassign);
    av_push(node, variable);
    av_push(node, value);
}

/* LIQ__make_if synthesize action
 * makes a building structure for new if node on output stack with accepted
 * markup tag token. The new node is pushs into parent node list in the first
 * time. The first empty clause is also pushs into the if node in this point.
 * Markup tag UNLESS is changed IF later at processing flip_unless.
 *
 *  block: IF {make_if} expression R {append_first} block
 *            elsif_clausese else_clause ENDIF R {end_node} block
 *  block: UNLESS {make_if} expression {flip_unless} R {append_first} block
 *            elsif_clausese else_clause ENDUNLESS R {end_node} block
 *
 * The if nodes are the list with clause nodes as similar as the LISP
 * language's cond special forms.
 *
 *      {%if x%}a{%elsif y%}b{%elsif z%}c{%else%}e{%endif%}
 *
 * is coded
 *
 *      [IF,
 *        [[VARIABLE, "x"], [PLAIN, "a"]],
 *        [[VARIABLE, "y"], [PLAIN, "b"]],
 *        [[VARIABLE, "z"], [PLAIN, "c"]],
 *        [ELSE, [PLAIN, "e"]]]
 *
 * example source: {% if x %}a{% endif %} ...
 * state changes:
 *
 *      C: (IF, IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (IF, {make_if}, expression, R, {append_first}, ..., @K)
 *
 *      C: (IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], IF)
 *      K: ({make_if}, expression, R, {append_first}, ..., @K)
 *
 *      C: (IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[] ]], #0#, #1#)
 *      K: (expression, R, {append_first}, block, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[] ]], #0#, #1#, [VARIABLE, "x"])
 *      K: (R, {append_first}, block, elsif_clauses, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[] ]], #0#, #1#, [VARIABLE, "x"], R)
 *      K: ({append_first}, block, elsif_clauses, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[[VARIABLE, "x"]] ]], #0#, #1#)
 *      K: (block, elsif_clauses, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[[VARIABLE, "x"]] ]], #0#, #1#)
 *      K: (PLAIN, {append}, elsif_clauses, ..., @K)
 *
 *      C: (ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"]] ]], #0#, #1#,
 *          [PLAIN, "a"])
 *      K: ({append}, elsif_clauses, ..., @K)
 *
 *      C: (ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]], #0#, #1#)
 *      K: (elsif_clauses, ..., @K)
 *
 * where #n# means labeled list itself with #n=.
 */
static
void
liq_make_if(AV *output)
{
    SV *markuptag;
    AV *node, *clause;
    SV **item;

    markuptag = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, markuptag);
    av_push(output, newRV_inc((SV *)node));

    clause = newAV();
    av_push(node, newRV_noinc((SV *)clause));
    av_push(output, newRV_inc((SV *)clause));
}

/* LIQ__flip_unless synthesize action
 * changes unless markup tag of node to if one, and complements expression.
 *
 *  block: UNLESS {make_if} expression {flip_unless} R {append_first} block
 *            elsif_clausese else_clause ENDUNLESS R {end_node} block
 *
 * example source: {%unless x%}a{%endunless%} ...
 * state changes:
 *
 *      C: (UNLESS, IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDUNLESS, R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (UNLESS, {make_if}, expression, {flip_unless}, ..., @K)
 *
 *      C: (IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDUNLESS, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], UNLESS)
 *      K: ({make_if}, expression, {flip_unless}, ..., @K)
 *
 *      C: (IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDUNLESS, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[UNLESS, #1=[] ]], #0#, #1#)
 *      K: (expression, {flip_unless}, R, {append_first}, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDUNLESS, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[UNLESS, #1=[] ]], #0#, #1#,
 *         #2=[VARIABLE, "x"])
 *      K: ({flip_unless}, R, {append_first}, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDUNLESS, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IF, #1=[] ]], #0#, #1#,
 *         [NOT, #2=[VARIABLE, "x"]])
 *      K: (R, {append_first}, ..., @K)
 */
static
void
liq_flip_unless(AV *output)
{
    SV *v0;
    SV **item;
    AV *exp;

    item = av_fetch(output, av_len(output) - 2, 0);
    av_store((AV *)SvRV(*item), 0, newSViv(LIQ_IF));

    v0 = av_pop(output);

    exp = newAV();
    av_push(output, newRV_noinc((SV *)exp));
    av_push(exp, newSViv(LIQ_NOT));
    av_push(exp, v0);
}

/* LIQ__end_node synthesize action
 * cleans output stack after building a node with deleting four items
 * from it. This is commonly used in several node-clause(s) nonterminal
 * processing.
 *
 *  block: IF {make_if} expression R {append_first} block
 *         elsif_clausese else_clause 
 *         ENDIF R {end_node} block
 *
 * example source: {%if x%}a{%endif%} ...
 * state changes:
 *
 *      C: (ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#)
 *      K: (ENDIF, R, {end_node}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#, ENDIF)
 *      K: (R, {end_node}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#, ENDIF, R)
 *      K: ({end_node}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, [IF, [[VARIABLE, "x"], [PLAIN, "a"]] ]])
 *      K: (block, @K)
 */
static
void
liq_end_node(AV *output)
{
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));
}

/* LIQ__make_case synthesize action
 * makes a building structure for new case node on output stack.
 *
 *  block: CASE value R {make_case} plains
 *         when_clauses else_clause ENDCASE R {end_node} block
 *
 * The structure is similar as if node.
 *
 *      {%case x%}{%when 1 %}a{%when 2, 3 %}b{%else%}e{%endcase%}
 *
 * is coded
 *
 *      [CASE,
 *        [[VARIABLE, "x"]],
 *        [[ [NUMBER, 1] ], [PLAIN, "a"]],
 *        [[ [NUMBER, 2], [NUMBER, 3] ], [PLAIN, "b"]],
 *        [ELSE, [PLAIN, "e"]]]
 *
 * example source: {% case x %}{%when 1 %} ...
 * state changes:
 *
 *      C: (CASE, IDENT("x"), R, WHEN, NUMBER([NUMBER, 1]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (CASE, value, R, {make_case}, plains, when_clauses, ..., @K)
 *
 *      C: (IDENT("x"), R, WHEN, NUMBER([NUMBER, 1]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], CASE)
 *      K: (value, R, {make_case}, plains, when_clauses, ..., @K)
 *
 *      C: (R, WHEN, NUMBER([NUMBER, 1]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], CASE, [VARIABLE, "x"])
 *      K: (R, {make_case}, plains, when_clauses, ..., @K)
 *
 *      C: (WHEN, NUMBER([NUMBER, 1]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], CASE, [VARIABLE, "x"], R)
 *      K: ({make_case}, plains, when_clauses, ..., @K)
 *
 *      C: (WHEN, NUMBER([NUMBER, 1]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, #1=[[VARIABLE, "x"]] ]], #0#, #1#)
 *      K: (plains, when_clauses, ..., @K)
 */
static
void
liq_make_case(AV *output)
{
    SV *markuptag, *value;
    AV *node, *child;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    value = av_pop(output);
    markuptag = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, markuptag);
    av_push(output, newRV_inc((SV *)node));

    child = newAV();
    av_push(node, newRV_noinc((SV *)child));
    av_push(child, value);
    av_push(output, newRV_inc((SV *)child));
}

/* LIQ__make_for synthesize action
 * makes building structure for 'for'-node.
 *
 *  block : FOR variable IN {srcmark} for_list {srcyank} {make_for}
 *          for_slice R {append_for_slice} block else_clause
 *          ENDFOR R {end_node} block
 *
 * To resume iterations with offset:continue, pair of two special actions
 * srcmark and srcyank is added. They paste source snipets 'for'-group name.
 * 
 * The structure is node-clauses tree.
 *
 *      {%for x in a%}b{%else%}e{%endfor%}
 *
 * is coded
 *
 *      [FOR,
 *        [[ [VARIABLE, "x"], [VARIABLE, "a"],
 *             [NUMBER, 0], [CONST, undef], undef, "b"]
 *         [PLAIN, "a"]],
 *        [ELSE, [PLAIN, "e"]]]
 *
 * where additional four parts in first clause are used slice processing.
 * first one is offset, second one is limit, third one is reversed,
 * and last one is offset:continue group name.
 *
 * example source: {%for x in a %}b{%endfor%} ...
 * state changes:
 *
 *      C: (FOR, IDENT("x"), IN, IDENT("a"), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (FOR, variable, IN, {srcmark}, for_list, {srcyank}, {make_for}, ..., @K)
 *
 *      C: (IDENT("x"), IN, IDENT("a"), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR)
 *      K: (variable, IN, {srcmark}, for_list, {srcyank}, {make_for}, ..., @K)
 *
 *      C: (IN, IDENT("a"), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR, [VARIABLE, "x"])
 *      K: (IN, {srcmark}, for_list, {srcyank}, {make_for}, ..., @K)
 *
 *      C: (IDENT("a"), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR, [VARIABLE, "x"], IN)
 *      K: ({srcmark}, for_list, {srcyank}, {make_for}, ..., @K)
 *
 *      C: (IDENT("a"), R, PLAIN([PLAIN, "b"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR, [VARIABLE, "x"], IN)
 *      K: (for_list, {srcyank}, {make_for}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR, [VARIABLE, "x"], IN, [VARIABLE, "a"])
 *      K: ({srcyank}, {make_for}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block], FOR, [VARIABLE, "x"], IN, [VARIABLE, "a"], "a ")
 *      K: ({make_for}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ]]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"])
 *      K: (for_slice, R, ..., @K)
 */
static
void
liq_make_for(AV *output)
{
    SV *formarkup, *variable, *list, *snipet;
    SV *group_source, *group;
    SV **item;
    AV *node, *clause, *bind, *slice, *exp;

    snipet = av_pop(output);
    list = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    variable = av_pop(output);
    formarkup = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, formarkup);
    av_push(output, newRV_inc((SV *)node));

    clause = newAV();
    av_push(node, newRV_noinc((SV *)clause));
    av_push(output, newRV_inc((SV *)clause));

    bind = newAV();
    av_push(clause, newRV_noinc((SV *)bind));
    av_push(bind, variable);
    av_push(bind, list);

    slice = newAV();
    av_push(output, newRV_noinc((SV *)slice));

    /* offset default [NUMBER, 0] */
    exp = newAV();
    av_push(slice, newRV_noinc((SV *)exp));
    av_push(exp, newSViv(LIQ_NUMBER));
    av_push(exp, newSViv(0));

    /* limit default [CONST, undef] */
    exp = newAV();
    av_push(slice, newRV_noinc((SV *)exp));
    av_push(exp, newSViv(LIQ_CONST));
    av_push(exp, &PL_sv_undef);

    /* reversed default undef */
    av_push(slice, &PL_sv_undef);

    /* group name for offset:continue */
    group = newSVpvn("for ", 4);
    av_push(slice, group);
    group_source = liq_trim_spaces(snipet); /* s{\s+}{}gmsx */
    sv_catsv(group, group_source);
    SvREFCNT_dec(snipet);
    SvREFCNT_dec(group_source);
}

/* LIQ__append_for_slice synthesize action
 * appends 'for'-bind list and 'for'-slice list.
 *
 *  block : FOR variable IN {srcmark} for_list {srcyank} {make_for}
 *          for_slice R {append_for_slice} block else_clause
 *          ENDFOR R {end_node} block
 *
 * example source: {%for x in a %}b{%endfor%} ...
 * state changes:
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ] ]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"])
 *      K: (R, {append_for_slice}, block, else_clause, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ] ]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          R)
 *      K: ({append_for_slice}, block, else_clause, ENDFOR, R, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR,
                      #1=[[ [VARIABLE, "x"], [VARIABLE, "a"],
                            [NUMBER, 0], [CONST, undef], undef, "for a" ]]]],
 *          #0#, #1#)
 *      K: (block, else_clause, ENDFOR, R, ..., @K)
 */
static
void
liq_append_for_slice(AV *output)
{
    IV i, n;
    SV *rv_slice;
    AV *slice;
    SV **item;
    AV *bind;

    SvREFCNT_dec(av_pop(output));
    rv_slice = av_pop(output);

    /* push @{$output[-1][0]}, @{$rv_slice} */
    item = av_fetch(output, av_len(output), 0);
    item = av_fetch((AV *)SvRV(*item), 0, 0);
    bind = (AV *)SvRV(*item);

    slice = (AV *)SvRV(rv_slice);
    n = av_len(slice);
    for (i = 0; i <= n; i++) {
        item = av_fetch(slice, i, 0);
        if (item && SvOK(*item))
            av_push(bind, SvREFCNT_inc(*item));
        else
            av_push(bind, &PL_sv_undef);
    }
    SvREFCNT_dec(rv_slice);
}

/* LIQ__make_capture synthesize action
 * makes a building structure for new capture node on output stack.
 *
 *  block: CAPTURE variable {make_capture} pipeline R {append_first} block
 *         ENDCAPTURE R {end_node} block
 *
 * The structure is similar as if node.
 *
 *      {%capture x%}a{%endcapture%}
 *
 * is coded
 *
 *      [CAPTURE,
 *        [ [[VARIABLE, "x"]], [PLAIN, "a"] ]]
 *
 * example source: {%capture x%}a{%endcapture%} ...
 * state changes:
 *
 *      C: (CAPTURE, IDENT("x"), R, PLAIN([PLAIN, "a"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (CAPTURE, variable, {make_capture}, pipeline, R, ..., @K)
 *
 *      C: (IDENT("x"), R, PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], CAPTURE)
 *      K: (variable, {make_capture}, pipeline, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], CAPTURE, [VARIABLE, "x"])
 *      K: ({make_capture}, pipeline, R, {append_first}, block, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CAPTURE, #1=[] ]],
 *          #0#, #1#, [[VARIABLE, "x"]])
 *      K: (pipeline, R, {append_first}, block, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CAPTURE, #1=[] ]],
 *          #0#, #1#, [[VARIABLE, "x"]])
 *      K: (R, {append_first}, block, ENDCAPTURE, R, {end_node}, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CAPTURE, #1=[] ]],
 *          #0#, #1#, [[VARIABLE, "x"]], R)
 *      K: ({append_first}, block, ENDCAPTURE, R, {end_node}, block, @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDCAPTURE, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CAPTURE, #1=[ [[VARIABLE, "x"]] ] ]],
 *          #0#, #1#)
 *      K: (block, ENDCAPTURE, R, {end_node}, block, @K)
 */
static
void
liq_make_capture(AV *output)
{
    SV *capturemarkup, *variable;
    AV *node, *clause, *variable_part;
    SV **item;

    variable = av_pop(output);
    capturemarkup = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, capturemarkup);
    av_push(output, newRV_inc((SV *)node));

    clause = newAV();
    av_push(node, newRV_noinc((SV *)clause));
    av_push(output, newRV_inc((SV *)clause));

    variable_part = newAV();
    av_push(output, newRV_noinc((SV *)variable_part));
    av_push(variable_part, variable);
}

/* LIQ__append_increment synthesize action
 * appends a decrement or a increment node into the parent block node.
 *
 *  block: DECREMENT variable R {append_increment} block
 *  block: INCREMENT variable R {append_increment} block
 *
 * example source: {%increment x%} ...
 * state changes:
 *
 *      C: (INCREMENT, IDENT("x"), R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (INCREMENT, variable, R, {append_increment}, block, @K)
 *
 *      C: (IDENT("x"), R, @INPUTS)
 *      E: (@OUTPUTS, [@block], INCREMENT)
 *      K: (variable, R, {append_increment}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], INCREMENT, [VARIABLE, "x"])
 *      K: (R, {append_increment}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block], INCREMENT, [VARIABLE, "x"], R)
 *      K: ({append_increment}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, [INCREMENT, [VARIABLE, "x"]]])
 *      K: (block, @K)
 */
static
void
liq_append_increment(AV *output)
{
    SV *tagmarkup, *variable;
    AV *node;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    variable = av_pop(output);
    tagmarkup = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, tagmarkup);
    av_push(node, variable);
}

/* LIQ__make_ifchanged synthesize action
 * makes a building structure for new ifchanged node on output stack.
 *
 *  block: IFCHANGED R {make_ifchanged} block
 *         ENDIFCHANGED R {end_ifchanged} block
 *
 * example source: {%ifchanged%}a{%endifchanged%} ...
 * state changes:
 *
 *      C: (IFCHANGED, R, PLAIN([PLAIN, "a"]), ENDIFCHANGED, R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (IFCHANGED, R, {make_ifchanged}, block, ENDIFCHANGED, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ENDIFCHANGED, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], IFCHANGED)
 *      K: (R, {make_ifchanged}, block, ENDIFCHANGED, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDIFCHANGED, R, @INPUTS)
 *      E: (@OUTPUTS, [@block], IFCHANGED, R)
 *      K: ({make_ifchanged}, block, ENDIFCHANGED, R, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ENDIFCHANGED, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IFCHANGED]], #0#)
 *      K: (block, ENDIFCHANGED, R, ..., @K)
 */
static
void
liq_make_ifchanged(AV *output)
{
    SV *ifchangedmarkup;
    AV *node;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    ifchangedmarkup = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, ifchangedmarkup);
    av_push(output, newRV_inc((SV *)node));
}

/* LIQ__end_ifchanged synthesize action
 * cleans output stack after building a ifchanged node.
 *
 *  block: IFCHANGED R {make_ifchanged} block
 *         ENDIFCHANGED R {end_ifchanged} block
 *
 * example source: {%ifchanged%}a{%endifchanged%} ...
 * state changes:
 *
 *      C: (ENDIFCHANGED, R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IFCHANGED, [PLAIN, "a"]] ], #0#)
 *      K: (ENDIFCHANGED, R, {end_ifchanged}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IFCHANGED, [PLAIN, "a"]] ],
 *          #0#, ENDIFCHANGED)
 *      K: (R, {end_ifchanged}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[IFCHANGED, [PLAIN, "a"]] ],
 *          #0#, ENDIFCHANGED, R)
 *      K: ({end_ifchanged}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, [IFCHANGED, [PLAIN, "a"]] ])
 *      K: (block, @K)
 */
static
void
liq_end_ifchanged(AV *output)
{
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));
}

/* LIQ__make_include synthesize action
 * makes a new include node on output stack.
 *
 *  block: INCLUDE value {make_include}
 *         include_with include_arguments R {append_first} block
 *
 * An include node has five items.
 *
 *  [INCLUDE, $file, $for_variable, [@parameters], [@arguments]]
 * 
 * example source: {%include 'a' %} ...
 * state changes:
 *
 *      C: (INCLUDE, STRING([STRING, "a"]), R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (INCLUDE, value, {make_include}, include_with, ..., @K)
 *
 *      C: (STRING([STRING, "a"]), R, @INPUTS)
 *      E: (@OUTPUTS, [@block], INCLUDE)
 *      K: (value, {make_include}, include_with, ..., @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], INCLUDE, [STRING, "a"])
 *      K: ({make_include}, include_with, ..., @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], [INCLUDE, [STRING, "a"], undef, [], []])
 *      K: (include_with, include_arguments, R, {append_first}, block, @K)
 */
static
void
liq_make_include(AV *output)
{
    SV *includemarkup, *file;
    AV *node;

    file = av_pop(output);
    includemarkup = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, includemarkup);
    av_push(node, file);
    av_push(node, &PL_sv_undef);
    av_push(node, newRV_noinc((SV *)newAV()));
    av_push(node, newRV_noinc((SV *)newAV()));
}

/* LIQ__append_break synthesize action
 * makes a new break/continue node and pushs it into parent node.
 *
 *  block: BREAK    R {append_break} block
 *  block: CONTINUE R {append_break} block
 *
 * example source: {%break%} ...
 * state changes:
 *
 *      C: (BREAK, R, @INPUTS)
 *      E: (@OUTPUTS, [@block])
 *      K: (BREAK, R, {append_break}, block, @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [@block], BREAK)
 *      K: (R, {append_break}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block], BREAK, R)
 *      K: ({append_break}, block, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [@block, [BREAK] ])
 *      K: (block, @K)
 */
static
void
liq_append_break(AV *output)
{
    SV *tagmarkup;
    AV *node;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    tagmarkup = av_pop(output);

    node = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)node));
    av_push(node, tagmarkup);
}

/* LIQ_elsif_clauses nonterminal rules
 *
 *  elsif_clauses
 *    :
 *    | ELSIF {make_elsif} expression R {append_first} block elsif_clauses
 */
static
IV
liq_rule_elsif_clauses(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_ELSIF:
        liq_unshift_symbols(stack, 7,
            LIQ_ELSIF, LIQ__make_elsif, LIQ_expression, LIQ_R,
            LIQ__append_first, LIQ_block, LIQ_elsif_clauses);
        break;
    case LIQ_ELSE:
    case LIQ_ENDIF:
    case LIQ_ENDUNLESS:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_elsif synthesize action
 * updates a building structure for current if node on output stack.
 *
 *  elsif_clauses: ELSIF {make_elsif} expression R {append_first} block
 *                 elsif_clausese
 *
 * example source: {%if x%}a{%elsif y%}b{% endif %} ...
 * state changes:
 *
 *      C: (ELSIF, IDENT("y"), R, PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]], #0#, #1#)
 *      K: (ELSIF, {make_elsif}, expression, R, ..., @K)
 *
 *      C: (IDENT("y"), R, PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#, ELSIF)
 *      K: ({make_elsif}, expression, R, {append_first}, block, ..., @K)
 *
 *      C: (IDENT("y"), R, PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[] ]],
 *          #0#, #2#)
 *      K: (expression, R, {append_first}, block, elsif_clausese, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[] ]],
 *          #0#, #2#, [VARIABLE, "y"])
 *      K: (R, {append_first}, block, elsif_clausese, else_clause, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[] ]],
 *          #0#, #2#, [VARIABLE, "y"], R)
 *      K: ({append_first}, block, elsif_clausese, else_clause, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "b"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[[VARIABLE, "y"]] ]],
 *          #0#, #2#)
 *      K: (block, elsif_clausese, else_clause, ..., @K)
 *
 *      C: (ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[[VARIABLE, "y"], [PLAIN, "b"]] ]],
 *          #0#, #2#)
 *      K: (elsif_clausese, else_clause, ..., @K)
 */
static
void
liq_make_elsif(AV *output)
{
    AV *clause;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));

    clause = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)clause));
    av_push(output, newRV_inc((SV *)clause));
}

/* LIQ_plains nonterminal rules
 * adds optional plains between case markup and when markup.
 *
 *  plains :
 *         | PLAIN {append} plains
 */
static
IV
liq_rule_plains(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_PLAIN:
        liq_unshift_symbols(stack, 3, LIQ_PLAIN, LIQ__append, LIQ_plains);
        break;    
    case LIQ_WHEN:
    case LIQ_ELSE:
    case LIQ_ENDCASE:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_when_clauses nonterminal rules
 *
 *  when_clauses
 *    :
 *    | WHEN value {make_when} when_values R {append_first} block when_clauses
 */
static
IV
liq_rule_when_clauses(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_WHEN:
        liq_unshift_symbols(stack, 8,
            LIQ_WHEN, LIQ_value, LIQ__make_when, LIQ_when_values, LIQ_R,
            LIQ__append_first, LIQ_block, LIQ_when_clauses);
        break;
    case LIQ_ELSE:
    case LIQ_ENDCASE:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_when synthesize action
 * updates a building structure for current case node on output stack.
 *
 *  when_clauses: WHEN value {make_when} when_values R {append_first} block
 *                when_clauses
 *
 * example source: {% case x %}{%when 1,2 %}a ...
 * state changes:
 *
 *      C: (WHEN, NUMBER([NUMBER, 1]), COMMA, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, #1=[[VARIABLE, "x"]] ]], #0#, #1#)
 *      K: (WHEN, value, {make_when}, when_values, R, ..., @K)
 *
 *      C: (NUMBER([NUMBER, 1]), COMMA, NUMBER([NUMBER, 2]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, #1=[[VARIABLE, "x"]] ]],
 *          #0#, #1#, WHEN)
 *      K: (value, {make_when}, when_values, R, {append_first}, ..., @K)
 *
 *      C: (COMMA, NUMBER([NUMBER, 2]), R, PLAIN([PLAIN, "a"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, #1=[[VARIABLE, "x"]] ]],
 *          #0#, #1#, WHEN, [NUMBER, 1])
 *      K: ({make_when}, when_values, R, {append_first}, block, ..., @K)
 *
 *      C: (COMMA, NUMBER([NUMBER, 2]), R, PLAIN([PLAIN, "a"])..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, [[VARIABLE, "x"]],
 *                                    #2=[] ]],
 *          #0#, #2#, [[NUMBER, 1]])
 *      K: (when_values, R, {append_first}, block, when_clauses, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "a"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, [[VARIABLE, "x"]],
 *                                    #2=[] ]],
 *          #0#, #2#, [[NUMBER, 1], [NUMBER, 2]])
 *      K: (R, {append_first}, block, when_clauses, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, [[VARIABLE, "x"]],
 *                                    #2=[] ]],
 *          #0#, #2#, [[NUMBER, 1], [NUMBER, 2]], R)
 *      K: ({append_first}, block, when_clauses, ..., @K)
 *
 *      C: (PLAIN([PLAIN, "a"]), ..., @INPUTS)
 *      E: (@OUTPUTS, [@block, #0=[CASE, [[VARIABLE, "x"]],
 *                                    #2=[ [[NUMBER, 1], [NUMBER, 2]] ] ]],
 *          #0#, #2#)
 *      K: (block, when_clauses, ..., @K)
 */
static
void
liq_make_when(AV *output)
{
    SV *value;
    AV *clause, *alt;
    SV **item;

    value = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    SvREFCNT_dec(av_pop(output));

    clause = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)clause));
    av_push(output, newRV_inc((SV *)clause));

    alt = newAV();
    av_push(output, newRV_noinc((SV *)alt));
    av_push(alt, value);
}

/* LIQ_if_else_clause nonterminal rules
 *
 *  if_else_clause
 *      :
 *      | else_clause
 */
static
IV
liq_rule_if_else_clause(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_ELSE:
        liq_unshift_symbols(stack, 1,
            LIQ_else_clause);
        break;
    case LIQ_ENDIF:
    case LIQ_ENDUNLESS:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_case_else_clause nonterminal rules
 *
 *  case_else_clause
 *      :
 *      | else_clause
 */
static
IV
liq_rule_case_else_clause(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_ELSE:
        liq_unshift_symbols(stack, 1,
            LIQ_else_clause);
        break;
    case LIQ_ENDCASE:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_for_else_clause nonterminal rules
 *
 *  for_else_clause
 *      :
 *      | else_clause
 */
static
IV
liq_rule_for_else_clause(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_ELSE:
        liq_unshift_symbols(stack, 1,
            LIQ_else_clause);
        break;
    case LIQ_ENDFOR:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_else_clause nonterminal rules
 *
 *  else_clause : ELSE R {make_else} block
 */
static
IV
liq_rule_else_clause(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_ELSE:
        liq_unshift_symbols(stack, 4,
            LIQ_ELSE, LIQ_R, LIQ__make_else, LIQ_block);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_else synthesize action
 * updates a building structure for current if/case/for node on output stack.
 *
 *  else_clause: ELSE R {make_else} block
 *
 * example source: {%if x%}a{%else%}e{%endif%}
 * state changes:
 *
 *      C: (ELSE, R, PLAIN([PLAIN, "e"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#)
 *      K: (ELSE, R, {make_else}, block, ENDIF, R, {end_node}, block, @K)
 *
 *      C: (R, PLAIN([PLAIN, "e"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#, ELSE)
 *      K: (R, {make_else}, block, ENDIF, R, {end_node}, block, @K)
 *
 *      C: (PLAIN([PLAIN, "e"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, #1=[[VARIABLE, "x"], [PLAIN, "a"]] ]],
 *          #0#, #1#, ELSE, R)
 *      K: ({make_else}, block, ENDIF, R, {end_node}, block, @K)
 *
 *      C: (PLAIN([PLAIN, "e"]), ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[ELSE] ]],
 *          #0#, #2#)
 *      K: (block, ENDIF, R, {end_node}, block, @K)
 *
 *      C: (ENDIF, R, @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[IF, [[VARIABLE, "x"], [PLAIN, "a"]],
 *                        #2=[ELSE, [PLAIN, "e"]] ]],
 *          #0#, #2#)
 *      K: (ENDIF, R, {end_node}, block, @K)
 */
static
void
liq_make_else(AV *output)
{
    SV *elsemarkup;
    AV *clause;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    elsemarkup = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    clause = newAV();
    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), newRV_noinc((SV *)clause));
    av_push(clause, elsemarkup);
    av_push(output, newRV_inc((SV *)clause));
}

/* LIQ_pipeline nonterminal rules
 *
 *  pipeline :
 *           | FILTER IDENT {make_filter} filter_arguments {append} pipeline
 */
static
IV
liq_rule_pipeline(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_FILTER:
        liq_unshift_symbols(stack, 6,
            LIQ_FILTER, LIQ_IDENT, LIQ__make_filter,
            LIQ_filter_arguments, LIQ__append, LIQ_pipeline);
        break;
    case LIQ_R:
    case LIQ_RR:
    case LIQ_RRR:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_filter synthesize action
 * makes a new filter node.
 *
 *  pipeline: FILTER IDENT {make_filter} filter_arguments {append} pipeline
 *
 * example source: {{ x | f }}
 * state changes:
 *
 *      C: (FILTER, IDENT("f"), RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]])
 *      K: (FILTER, IDENT, {make_filter}, filter_arguments, ..., @K)
 *
 *      C: (IDENT("f"), RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]], FILTER)
 *      K: (IDENT, {make_filter}, filter_arguments, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]], FILTER, "f")
 *      K: ({make_filter}, filter_arguments, {append}, pipeline, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]], [FILTER, "f"])
 *      K: (filter_arguments, {append}, pipeline, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"]], [FILTER, "f"])
 *      K: ({append}, pipeline, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@block], [ESCAPE, [VARIABLE, "x"], [FILTER, "f"]])
 *      K: (pipeline, ..., @K)
 */
static
void
liq_make_filter(AV *output)
{
    SV *filtertag, *filtername;
    AV *node;

    filtername = av_pop(output);
    filtertag = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, filtertag);
    av_push(node, filtername);
}

/* LIQ_filter_arguments nonterminal rules
 *
 *  filter_arguments
 *    :
 *    | COLON value {append_second} filter_comma_arguments
 */
static
IV
liq_rule_filter_arguments(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_COLON:
        liq_unshift_symbols(stack, 4,
            LIQ_COLON, LIQ_value, LIQ__append_second,
            LIQ_filter_comma_arguments);
        break;
    case LIQ_FILTER:
    case LIQ_R:
    case LIQ_RR:
    case LIQ_RRR:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__append_second synthesize action
 * after pops two items from output stack, appends top of stack and poped second.
 *
 *  filter_arguments: COLON value {append_second} filter_comma_arguments
 *  filter_comma_arguments: COMMA value {append_second} filter_comma_arguments
 *  when_values: COMMA value {append_second} when_values
 *  when_values: OR value {append_second} when_values
 *  selectors: DOT IDENT {append_second} selectors
 *
 * example source: {{ x | f:'a' }}
 * state changes:
 *
 *      C: (COLON, STRING([STRING, "a"]), RR, @INPUTS)
 *      E: (@OUTPUTS, [@node], [FILTER, "f"])
 *      K: (COLON, value, {append_second}, filter_comma_arguments, ..., @K)
 *
 *      C: (STRING([STRING, "a"]), RR, @INPUTS)
 *      E: (@OUTPUTS, [@node], [FILTER, "f"], COLON)
 *      K: (value, {append_second}, filter_comma_arguments, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@node], [FILTER, "f"], COLON, [STRING, "a"])
 *      K: ({append_second}, filter_comma_arguments, ..., @K)
 *
 *      C: (RR, @INPUTS)
 *      E: (@OUTPUTS, [@node], [FILTER, "f", [STRING, "a"]])
 *      K: (filter_comma_arguments, ..., @K)
 */
static
void
liq_append_second(AV *output)
{
    SV *v;
    SV **item;

    v = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), v);
}

/* LIQ_filter_comma_arguments nonterminal rules
 *
 *  filter_comma_arguments
 *    :
 *    | COMMA value {append_second} filter_comma_arguments
 */
static
IV
liq_rule_filter_comma_arguments(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_COMMA:
        liq_unshift_symbols(stack, 4,
            LIQ_COMMA, LIQ_value, LIQ__append_second,
            LIQ_filter_comma_arguments);
        break;
    case LIQ_FILTER:
    case LIQ_R:
    case LIQ_RR:
    case LIQ_RRR:
        /* empty */;
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_for_list nonterminal rules
 *
 *  for_list : LPAREN value RANGE value RPAREN {for_list_range}
 *           | value
 */
static
IV
liq_rule_for_list(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_LPAREN:
        liq_unshift_symbols(stack, 6,
            LIQ_LPAREN, LIQ_value, LIQ_RANGE, LIQ_value, LIQ_RPAREN,
            LIQ__for_list_range);
        break;
    case LIQ_CONST:
    case LIQ_IDENT:
    case LIQ_STRING:
    case LIQ_NUMBER:
        liq_unshift_symbols(stack, 1, LIQ_value);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__for_list_range synthesize action
 * makes range expression node.
 *
 *  for_list: LPAREN value RANGE value RPAREN {for_list_range}
 *
 * example source: (1..5)
 * state changes:
 *
 *      C: (LPAREN, NUMBER([NUMBER, 1]), RANGE, ..., @INPUTS)
 *      E: (@OUTPUTS)
 *      K: (LPAREN, value, RANGE, value, RPAREN, {for_list_range}, @K)
 *
 *      ...snip
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, LPAREN, [NUMBER, 1], RANGE, [NUMBER, 5], RPAREN)
 *      K: ({for_list_range}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [RANGE, [NUMBER, 1], [NUMBER, 5]])
 *      K: (@K)
 */
static
void
liq_make_for_list_range(AV *output)
{
    SV *fromvalue, *rangetag, *tovalue;
    AV *node;

    SvREFCNT_dec(av_pop(output));
    tovalue = av_pop(output);
    rangetag = av_pop(output);
    fromvalue = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, rangetag);
    av_push(node, fromvalue);
    av_push(node, tovalue);
}

/* LIQ_for_slice nonterminal rules
 *
 *  for_slice :
 *            | IDENT COLON for_offset for_slice
 *            | REVERSED {set_for_reversed} for_slice
 */
static
IV
liq_rule_for_slice(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_IDENT:
        liq_unshift_symbols(stack, 4,
            LIQ_IDENT, LIQ_COLON, LIQ_for_offset, LIQ_for_slice);
        break;
    case LIQ_REVERSED:
        liq_unshift_symbols(stack, 3,
            LIQ_REVERSED, LIQ__set_for_reversed, LIQ_for_slice);
        break;
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__set_for_reversed synthesize action
 * turns reversed flag on.
 *
 *  for_slice : REVERSED {set_for_reversed} for_slice
 *
 * example source: {%for x in a reversed %}b{%endfor%} ...
 * state changes:
 *
 *      C: (REVERSED, R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ]]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"])
 *      K: (REVERSED, {set_for_reversed}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ]]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"], REVERSED)
 *      K: ({set_for_reversed}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [@block, #0=[FOR, #1=[ [[VARIABLE, "x"], [VARIABLE, "a"]] ]]],
 *          #0#, #1#,
 *          [[NUMBER, 0], [CONST, undef], REVERSED, "for a"])
 *      K: (for_slice, R, ..., @K)
 */
static
void
liq_set_for_reversed(AV *output)
{
    SV *reversed;
    SV **item;

    reversed = av_pop(output);
    item = av_fetch(output, av_len(output), 0);
    av_store((AV *)SvRV(*item), 2, reversed);
}

/* LIQ_for_offset nonterminal rules
 *
 *  for_offset : CONTINUE {set_offset_continue}
 *             | value {set_offset_value}
 *
 * rejects STRING and CONST from value.
 */
static
IV
liq_rule_for_offset(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_CONTINUE:
        liq_unshift_symbols(stack, 2,
            LIQ_CONTINUE, LIQ__set_offset_continue);
        break;
    case LIQ_IDENT:
    case LIQ_NUMBER:
        liq_unshift_symbols(stack, 2,
            LIQ_value, LIQ__set_offset_value);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__set_offset_continue synthesize action
 * turns offset continue.
 *
 *  for_offset : CONTINUE {set_offset_continue}
 *
 * example source: {%for x in a offset:continue %}b{%endfor%} ...
 * state changes:
 *
 *      C: (IDENT("offset"), COLON, CONTINUE, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"])
 *      K: (IDENT, COLON, for_offset, for_slice, R, ..., @K)
 *
 *      C: (CONTINUE, R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON)
 *      K: (for_offset, for_slice, R, ..., @K)
 *
 *      C: (CONTINUE, R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON)
 *      K: (CONTINUE, {set_offset_continue}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON, CONTINUE)
 *      K: ({set_offset_continue}, for_slice, R, ..., @K)
 *
 *      C: (R, PLAIN([PLAIN, "b"]), ENDFOR, R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[CONTINUE], [CONST, undef], undef, "for a"])
 *      K: (for_slice, R, ..., @K)
 */
static
void
liq_set_offset_continue(AV *output)
{
    SV *sv_ident, *continuetag;
    AV *node;
    U8 *ident;
    STRLEN nident;
    SV **item;

    continuetag = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    sv_ident = av_pop(output);
    ident = SvPV(sv_ident, nident);
    if (strEQ(ident, "offset")) {
        node = newAV();
        item = av_fetch(output, av_len(output), 0);
        av_store((AV *)SvRV(*item), 0, newRV_noinc((SV *)node));
        av_push(node, SvREFCNT_inc(continuetag));
    }
    SvREFCNT_dec(continuetag);
    SvREFCNT_dec(sv_ident);
}

/* LIQ__set_offset_value synthesize action
 * sets offset or limit value.
 *
 *  for_offset : value {set_offset_value}
 *
 * example source: {%for x in a offset:20 limit:10 %}b{%endfor%} ...
 * state changes:
 *
 *      C: (IDENT("offset"), COLON, NUMBER([NUMBER, 20]), ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"])
 *      K: (IDENT, COLON, for_offset, for_slice, R, ..., @K)
 *
 *      C: (NUMBER([NUMBER, 20]), IDENT("limit"), COLON, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON)
 *      K: (for_offset, for_slice, R, ..., @K)
 *
 *      C: (NUMBER([NUMBER, 20]), IDENT("limit"), COLON, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON)
 *      K: (value, {set_offset_value}, for_slice, R, ..., @K)
 *
 *      C: (IDENT("limit"), COLON, NUMBER([NUMBER, 10]), R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 0], [CONST, undef], undef, "for a"],
 *          "offset", COLON, [NUMBER, 20])
 *      K: ({set_offset_value}, for_slice, R, ..., @K)
 *
 *      C: (IDENT("limit"), COLON, NUMBER([NUMBER, 10]), R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 20], [CONST, undef], undef, "for a"])
 *      K: (for_slice, R, ..., @K)
 *
 *      ..snip..
 *
 *      C: (R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 20], [CONST, undef], undef, "for a"]
 *          "limit", COLON, [NUMBER, 10])
 *      K: ({set_offset_value}, for_slice, R, ..., @K)
 *
 *      C: (R, ..., @INPUTS)
 *      E: (@OUTPUTS,
 *          [[NUMBER, 20], [NUMBER, 10], undef, "for a"])
 *      K: (for_slice, R, ..., @K)
 */
static
void
liq_set_offset_value(AV *output)
{
    SV *v0, *v2;
    U8 *p0;
    STRLEN n0;
    SV **item;

    v2 = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    v0 = av_pop(output);
    p0 = SvPV(v0, n0);
    item = av_fetch(output, av_len(output), 0);
    if (strEQ(p0, "offset")) {
        av_store((AV *)SvRV(*item), 0, SvREFCNT_inc(v2));
    }
    else if (strEQ(p0, "limit")) {
        av_store((AV *)SvRV(*item), 1, SvREFCNT_inc(v2));
    }
    SvREFCNT_dec(v2);
    SvREFCNT_dec(v0);
}

/* LIQ_when_values nonterminal rules
 *
 *  when_values :
 *              | OR    value {append_second} when_values
 *              | COMMA value {append_second} when_values
 */
static
IV
liq_rule_when_values(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_OR:
        liq_unshift_symbols(stack, 4,
            LIQ_OR, LIQ_value, LIQ__append_second, LIQ_when_values);
        break;
    case LIQ_COMMA:
        liq_unshift_symbols(stack, 4,
            LIQ_COMMA, LIQ_value, LIQ__append_second, LIQ_when_values);
        break;
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_include_with nonterminal rules
 *
 *  include_with :
 *               | WITH variable {include_with}
 *               | FOR  variable {include_with}
 */
static
IV
liq_rule_include_with(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_WITH:
        liq_unshift_symbols(stack, 3,
            LIQ_WITH, LIQ_variable, LIQ__include_with);
        break;
    case LIQ_FOR:
        liq_unshift_symbols(stack, 3,
            LIQ_FOR, LIQ_variable, LIQ__include_with);
        break;
    case LIQ_IDENT:
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__include_with synthesize action
 * sets optional include with/for variable.
 *
 *  include_with : WITH variable {include_with}
 *  include_with : FOR  variable {include_with}
 *
 * example source: {%include 'a' with b %} ...
 * state changes:
 *
 *      C: (WITH, IDENT("b"), R, @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef, [], []])
 *      K: (WITH, variable, {include_with}, include_arguments, ..., @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef, [], []],
 *          WITH, [VARIABLE, "b"])
 *      K: ({include_with}, include_arguments, ..., @K)
 *
 *      C: (R, @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], [VARIABLE, "b"], [], []])
 *      K: (include_arguments, ..., @K)
 */
static
void
liq_set_include_with(AV *output)
{
    SV *variable;
    SV **item;

    variable = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    item = av_fetch(output, av_len(output), 0);
    av_store((AV *)SvRV(*item), 2, variable);
}

/* LIQ_include_arguments nonterminal rules
 *
 *  include_arguments
 *    :
 *    | variable COLON value {append_include_arguments} include_comma
 *      include_arguments
 */
static
IV
liq_rule_include_arguments(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_IDENT:
        liq_unshift_symbols(stack, 6,
            LIQ_variable, LIQ_COLON, LIQ_value, LIQ__append_include_arguments,
            LIQ_include_comma, LIQ_include_arguments);
        break;
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__append_include_arguments synthesize action
 * adds optional include pair of a parameter and an argument.
 *
 *  include_arguments : variable COLON value {append_include_arguments}
 *
 * example source: {%include 'a' u:2 v:3 %} ...
 * state changes:
 *
 *      C: (IDENT("u"), COLON, NUMBER([NUMBER, 2]), ..., @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef, [], []])
 *      K: (variable, COLON, value, {append_include_arguments}, ..., @K)
 *
 *      C: (IDENT("v"), COLON, NUMBER([NUMBER, 3]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef, [], []],
 *          [VARIABLE, "u"], COLON, [NUMBER, 2])
 *      K: ({append_include_arguments}, include_arguments, ..., @K)
 *
 *      C: (IDENT("v"), COLON, NUMBER([NUMBER, 3]), R, ..., @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef,
 *                     [[VARIABLE, "u"]], [[NUMBER, 2]]])
 *      K: (include_arguments, ..., @K)
 *
 *      ..snip..
 *
 *      C: (R, ..., @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef,
 *                     [[VARIABLE, "u"]], [[NUMBER, 2]]],
 *         [VARIABLE, "v"], COLON, [NUMBER, 3])
 *      K: ({append_include_arguments}, include_arguments, ..., @K)
 *
 *      C: (R, ..., @INPUTS)
 *      E: (@OUTPUTS, [INCLUDE, [STRING, "a"], undef,
 *                     [[VARIABLE, "u"], [VARIABLE, "v"]],
 *                     [[NUMBER, 2], [NUMBER, 3]]])
 *      K: (include_arguments, ..., @K)
 */
static
void
liq_append_include_arguments(AV *output)
{
    SV *parameter, *argument;
    AV *node;
    SV **item;

    argument = av_pop(output);
    SvREFCNT_dec(av_pop(output));
    parameter = av_pop(output);

    item = av_fetch(output, av_len(output), 0);
    node = (AV *)SvRV(*item);
    item = av_fetch(node, 3, 0);
    av_push((AV *)SvRV(*item), parameter);
    item = av_fetch(node, 4, 0);
    av_push((AV *)SvRV(*item), argument);
}

/* LIQ_include_comma nonterminal rules
 * skip optional comma.
 * 
 *  include_comma :
 *                | COMMA {ignore}
 */
static
IV
liq_rule_include_comma(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_COMMA:
        liq_unshift_symbols(stack, 2, LIQ_COMMA, LIQ__ignore);
        break;
    case LIQ_IDENT:
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__ignore synthesize action
 * drops top of output stack.
 *
 *  include_comma : COMMA {ignore}
 *
 * state changes:
 *
 *      C: (COMMA, @INPUTS)
 *      E: (@OUTPUTS)
 *      K: (COMMA, {ignore}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, COMMA)
 *      K: ({ignore}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS)
 *      K: (@K)
 */
static
void
liq_ignore(AV *output)
{
    SvREFCNT_dec(av_pop(output));
}

/* LIQ_expression nonterminal rules
 * logical expression used if/unless markup.
 *
 *   expression : expression3 expression2 expression1
 */
static
IV
liq_rule_expression(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_NOT:
    case LIQ_LPAREN:
    case LIQ_CONST:
    case LIQ_IDENT:
    case LIQ_STRING:
    case LIQ_NUMBER:
        liq_unshift_symbols(stack, 3,
            LIQ_expression3, LIQ_expression2, LIQ_expression1);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_expression1 nonterminal rules
 *
 *  expression1 :
 *              | OR expression3 expression2 {make_binary} expression1
 */
static
IV
liq_rule_expression1(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_OR:
        liq_unshift_symbols(stack, 5,
            LIQ_OR, LIQ_expression3, LIQ_expression2, LIQ__make_binary,
            LIQ_expression1);
        break;
    case LIQ_RPAREN:
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_expression2 nonterminal rules
 *
 *  expression2 :
 *              | AND expression3 {make_binary} expression2
 */
static
IV
liq_rule_expression2(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_AND:
        liq_unshift_symbols(stack, 4,
            LIQ_AND, LIQ_expression3, LIQ__make_binary, LIQ_expression2);
        break;
    case LIQ_OR:
    case LIQ_RPAREN:
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_binary synthesize action
 * makes expression node of binary operator.
 *
 * state changes:
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, $left_hand_side, $operator, $right_hand_side)
 *      K: ({make_binary}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [$operator, $left_hand_side, $right_hand_side])
 *      K: (@K)
 */
static
void
liq_make_binary(AV *output)
{
    SV *lhs, *operator, *rhs;
    AV *node;

    rhs = av_pop(output);
    operator = av_pop(output);
    lhs = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, operator);
    av_push(node, lhs);
    av_push(node, rhs);
}

/* LIQ_expression3 nonterminal rules
 *
 *  expression3 : LPAREN expression RPAREN {make_subexpression}
 *              | NOT value {make_unary} expression4
 *              | value expression4
 */
static
IV
liq_rule_expression3(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_LPAREN:
        liq_unshift_symbols(stack, 4,
            LIQ_LPAREN, LIQ_expression, LIQ_RPAREN, LIQ__make_subexpression);
        break;
    case LIQ_NOT:
        liq_unshift_symbols(stack, 4,
            LIQ_NOT, LIQ_value, LIQ__make_unary, LIQ_expression4);
        break;
    case LIQ_CONST:
    case LIQ_IDENT:
    case LIQ_STRING:
    case LIQ_NUMBER:
        liq_unshift_symbols(stack, 2, LIQ_value, LIQ_expression4);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_subexpression synthesize action
 * makes subexpression node.
 *
 * state changes:
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, LPAREN, $expression, RPAREN)
 *      K: ({make_subexpression}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, $expression)
 *      K: (@K)
 */
static
void
liq_make_subexpression(AV *output)
{
    SV *expression;

    SvREFCNT_dec(av_pop(output));
    expression = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    av_push(output, expression);
}

/* LIQ__make_unary synthesize action
 * makes unary operator expression node.
 *
 * state changes:
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, NOT, $value)
 *      K: ({make_unary}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [NOT, $value])
 *      K: (@K)
 */
static
void
liq_make_unary(AV *output)
{
    SV *operator, *value;
    AV *node;

    value = av_pop(output);
    operator = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, operator);
    av_push(node, value);
}

/* LIQ_expression4 nonterminal rules
 *
 *  expression4 :
 *              | CMP value {make_binary}
 */
static
IV
liq_rule_expression4(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_CMP:
        liq_unshift_symbols(stack, 3, LIQ_CMP, LIQ_value, LIQ__make_binary);
        break;
    case LIQ_OR:
    case LIQ_AND:
    case LIQ_RPAREN:
    case LIQ_R:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_value nonterminal rules
 *
 *  value : CONST | variable | STRING | NUMBER
 */
static
IV
liq_rule_value(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_CONST:
        liq_unshift_symbols(stack, 1, LIQ_CONST);
        break;
    case LIQ_IDENT:
        liq_unshift_symbols(stack, 1, LIQ_variable);
        break;
    case LIQ_STRING:
        liq_unshift_symbols(stack, 1, LIQ_STRING);
        break;
    case LIQ_NUMBER:
        liq_unshift_symbols(stack, 1, LIQ_NUMBER);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ_variable nonterminal rules
 *
 *  variable : IDENT {make_variable} selectors
 */
static
IV
liq_rule_variable(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_IDENT:
        liq_unshift_symbols(stack, 3,
            LIQ_IDENT, LIQ__make_variable, LIQ_selectors);
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__make_variable synthesize action
 * makes variable node.
 *
 * The variable node is a list of identifiers and values.
 *
 * Variable x.s.t[3].u coded
 * 
 *  [VARIABLE, "x", "s", "t", [NUMBER, 3], "u"]
 *
 * Variable x[i] coded
 *
 *  [VARIABLE, "x", [VARIABLE, "i"]]
 *
 * state changes:
 *
 *      C: (IDENT("x"), @INPUTS)
 *      E: (@OUTPUTS)
 *      K: (IDENT, {make_variable}, selectors, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, "x")
 *      K: ({make_variable}, selectors, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [VARIABLE, "x"])
 *      K: (selectors, @K)
 */
static
void
liq_make_variable(AV *output)
{
    SV *ident;
    AV *node;

    ident = av_pop(output);

    node = newAV();
    av_push(output, newRV_noinc((SV *)node));
    av_push(node, newSViv(LIQ_VARIABLE));
    av_push(node, ident);
}

/* LIQ_selectors nonterminal rules
 *
 *  selectors :
 *            | DOT IDENT {append_second} selectors
 *            | LSQUARE value RSQUARE {append_second3} selectors
 */
static
IV
liq_rule_selectors(AV *stack, IV next_token)
{
    IV ok = 1;

    switch (next_token) {
    case LIQ_DOT:
        liq_unshift_symbols(stack, 4,
            LIQ_DOT, LIQ_IDENT, LIQ__append_second, LIQ_selectors);
        break;
    case LIQ_LSQUARE:
        liq_unshift_symbols(stack, 5,
            LIQ_LSQUARE, LIQ_value, LIQ_RSQUARE, LIQ__append_second3,
            LIQ_selectors);
        break;
    case LIQ_EQUIV:
    case LIQ_IN:
    case LIQ_FILTER:
    case LIQ_R:
    case LIQ_RR:
    case LIQ_RRR:
    case LIQ_IDENT:
    case LIQ_COLON:
    case LIQ_WITH:
    case LIQ_FOR:
    case LIQ_OR:
    case LIQ_AND:
    case LIQ_COMMA:
    case LIQ_REVERSED:
    case LIQ_RANGE:
    case LIQ_RPAREN:
    case LIQ_RSQUARE:
    case LIQ_CMP:
        /* empty */
        break;
    default:
        ok = 0;
    }
    return ok;
}

/* LIQ__append_second3 synthesize action
 * adds second from three items.
 *
 * state changes:
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [VARIABLE, 'x'], LSQUARE, $value, RSQUARE)
 *      K: ({append_second3}, @K)
 *
 *      C: (@INPUTS)
 *      E: (@OUTPUTS, [VARIABLE, 'x', $value])
 *      K: (@K)
 */
static
void
liq_append_second3(AV *output)
{
    SV *value;
    SV **item;

    SvREFCNT_dec(av_pop(output));
    value = av_pop(output);
    SvREFCNT_dec(av_pop(output));

    item = av_fetch(output, av_len(output), 0);
    av_push((AV *)SvRV(*item), value);
}

/* dispatch table must be same order of LIQ_{nonterminal} symbols */
static
liq_nonteminal_rule_t liq_nonteminal_rules[] = {
    liq_rule_block,
    liq_rule_if_else_clause,
    liq_rule_case_else_clause,
    liq_rule_for_else_clause,
    liq_rule_else_clause,
    liq_rule_elsif_clauses,
    liq_rule_expression,
    liq_rule_expression1,
    liq_rule_expression2,
    liq_rule_expression3,
    liq_rule_expression4,
    liq_rule_filter_arguments,
    liq_rule_filter_comma_arguments,
    liq_rule_for_list,
    liq_rule_for_offset,
    liq_rule_for_slice,
    liq_rule_include_arguments,
    liq_rule_include_comma,
    liq_rule_include_with,
    liq_rule_pipeline,
    liq_rule_plains,
    liq_rule_selectors,
    liq_rule_value,
    liq_rule_variable,
    liq_rule_when_clauses,
    liq_rule_when_values
};

/* dispatch table must be same order of LIQ__{action} symbols */
static
liq_grammar_action_t liq_grammar_actions[] = {
    liq_append,
    liq_append_break,
    liq_append_first,
    liq_append_for_slice,
    liq_append_include_arguments,
    liq_append_increment,
    liq_append_second,
    liq_append_second3,
    liq_make_if,
    liq_end_ifchanged,
    liq_end_node,
    liq_make_for_list_range,
    liq_ignore,
    liq_set_include_with,
    liq_make_assign,
    liq_make_binary,
    liq_make_capture,
    liq_make_case,
    liq_make_else,
    liq_make_elsif,
    liq_make_escape,
    liq_make_filter,
    liq_make_for,
    liq_make_ifchanged,
    liq_make_include,
    liq_make_subexpression,
    liq_make_unary,
    liq_flip_unless,
    liq_make_variable,
    liq_make_when,
    liq_set_for_reversed,
    liq_set_offset_continue,
    liq_set_offset_value
};

/**
 * builds a symbolic array list from a Liquid markup token list.
 * 
 * SV *source   source string scalar.
 * SV *rv_token_list  token list.
 *
 * SV *         symbolic array list.
 */
static
SV *
liq_parse(SV *source, SV* rv_token_list)
{
    IV token_pointer, possrc, symbol;
    IV next_token;
    AV *array, *token_list, *stack, *output, *root, *node;
    SV **item, **rv_token, *token_value, *svitem;
    SV *svsymbol;

    possrc = 0;

    if (! SvROK(rv_token_list) || SvTYPE(SvRV(rv_token_list)) != SVt_PVAV)
        return &PL_sv_undef;
    token_list = (AV *)SvRV(rv_token_list);

    token_pointer = 0;

    rv_token = av_fetch(token_list, token_pointer, 0);
    if (rv_token == NULL || ! SvROK(*rv_token))
        croak("xparse: token_list->[%d] is not token.\n",
              (int)token_pointer);
    array = (AV *)SvRV(*rv_token);
    if (SvTYPE((SV *)array) != SVt_PVAV)
        croak("xparse: token_list->[%d] is not token.\n",
              (int)token_pointer);
    item = av_fetch(array, 0, 0);
    if (item == NULL || ! SvOK(*item))
        croak("xparse: token_list->[%d][0] is not token_kind.\n",
              (int)token_pointer);
    next_token = SvIV(*item);

    root = (AV *)sv_2mortal((SV *)newAV());
    av_push(root, newSViv(LIQ_BEGIN));
    output = (AV *)sv_2mortal((SV *)newAV());
    av_push(output, newRV_inc((SV *)root));

    stack = (AV *)sv_2mortal((SV *)newAV());
    av_push(stack, newSViv(LIQ_block));
    av_push(stack, newSViv(LIQ_EOF));

    while (av_len(stack) >= 0) {
        svsymbol = av_shift(stack);
        symbol = SvIV(svsymbol);
        SvREFCNT_dec(svsymbol);

#if LIQK_TRACE
        PerlIO_printf(PerlIO_stdout(),
            "xparse: %2d . %3d ", (int)next_token, (int)symbol);
        liq_print_stack(stack);
        PerlIO_printf(PerlIO_stdout(), "\n");
#endif

        if (symbol == LIQ_EOF) {
            if (next_token == LIQ_EOF)
                break;
        }
        else if (symbol <= LIQK_TERM_LAST) {
            if (symbol != next_token)
                goto error;

            array = (AV *)SvRV(*rv_token);
            item = av_fetch(array, 1, 0);
            if (item == NULL || ! SvOK(*item))
                croak("xparse: token_list->[%d][1] is not token_value.\n",
                      (int)token_pointer);
            av_push(output, SvREFCNT_inc(*item));

            rv_token = av_fetch(token_list, ++token_pointer, 0);
            if (rv_token == NULL || ! SvROK(*rv_token))
                croak("xparse: token_list->[%d] is not token.\n",
                      (int)token_pointer);
            array = (AV *)SvRV(*rv_token);
            if (SvTYPE((SV *)array) != SVt_PVAV)
                croak("xparse: token_list->[%d] is not token.\n",
                      (int)token_pointer);
            item = av_fetch(array, 0, 0);
            if (item == NULL || ! SvOK(*item))
                croak("xparse: token_list->[%d][0] is not token_kind.\n",
                      (int)token_pointer);
            next_token = SvIV(*item);
            continue;
        }
        else if (symbol >= LIQK_ACTION_FIRST && symbol <= LIQK_ACTION_LAST) {
            liq_grammar_action_t action;

            action = liq_grammar_actions[symbol - LIQK_ACTION_FIRST];
            (*action)(output);
            continue;
        }
        else if (symbol >= LIQK_NONTERM_FIRST && symbol <= LIQK_NONTERM_LAST) {
            liq_nonteminal_rule_t rule;

            rule = liq_nonteminal_rules[symbol - LIQK_NONTERM_FIRST];
            if ((*rule)(stack, next_token))
                continue;
        }
        else if (symbol == LIQ__srcmark) {
            array = (AV *)SvRV(*rv_token);
            item = av_fetch(array, 2, 0);
            if (item == NULL || ! SvOK(*item))
                croak("xparse: token_list->[%d][2] is not token_pos.\n",
                      (int)token_pointer);
            possrc = SvIV(*item);
            continue;
        }
        else if (symbol == LIQ__srcyank) {
            IV cursrc;
            array = (AV *)SvRV(*rv_token);
            item = av_fetch(array, 2, 0);
            if (item == NULL || ! SvOK(*item))
                croak("xparse: token_list->[%d][2] is not token_pos.\n",
                      (int)token_pointer);
            cursrc = SvIV(*item);
            av_push(output, liq_substr(source, possrc, cursrc - possrc));
            continue;
        }
        else {
            croak("unknown symbol %d in the grammar rule.\n", (int)symbol);
        }
        goto error;
    }

    return (SV *)newRV_inc((SV *)root);

error:
    av_clear(root);

    node = newAV();
    av_push(root, newRV_noinc((SV *)node));
    av_push(node, newSViv(LIQ_ERROR));
    av_push(node, newSVpv("SyntaxError: parser.", 0));
    array = (AV *)SvRV(*rv_token);
    item = av_fetch(array, 2, 0);
    av_push(node, newSViv(SvIV(*item)));
    return (SV *)newRV_inc((SV *)root);
}

static
AV *
liq_tokenize_cycle_group(AV *node, IV u8src)
{
    IV i, len;
    STRLEN n;
    U8 * p;
    SV **item;
    SV *group;

    len = av_len(node);
    if (len < 2)
        return node;
    item = av_fetch(node, 1, 0);
    if (item == NULL || ! (SvOK(*item)))
        return node;
    p = SvPV(*item, n);
    group = newSVpvn("cycle ", 6);
    if (n) {
        sv_catsv(group, *item);
    }
    else {
        for (i = 2; i <= len; i++) {
            if (i > 2) {
                sv_catpv(group, " ");
            }
            item = av_fetch(node, i, 0);
            if (item != NULL && (SvOK(*item)))
                sv_catsv(group, *item);
        }
    }
    if (u8src)
        SvUTF8_on(group);
    av_store(node, 1, group);
    return node;
}

/**
 * tokenizes a given string source. The source might be UTF-8 encoding.
 * This is a Nondeterministic Finite Automaton (DFA) from following
 * double loop perl's tokenizer used in Text::Liq module.
 * 
 *  while($src =~ m{\G(.*?)(?:(\{\{\{?)\s*|\{%\s*(\w+)\s*)}gcmsx) {
 *      push @token_list, [PLAIN, $1];
 *      if ($2 eq '{{') { push @token_list, [ESCAPE, ESCAPE]; }
 *      elsif ($2 eq '{{{') { push @token_list, [ESCAPE, ESCAPE]; }
 *      elsif ($3) { push @token_list, [$TOKEN{$3}, $TOKEN{$3}]; }
 *      while ($src =~ m{\G(?:$PUNCTTOK|$WORDTOK|$NUMTOK|$STRTOK)\s*}gcmsx) {
 *          my $t = $LAST_PAREN_MATCH;
 *          push @token_list, [TOKEN_KIND $t, TOKEN_VALUE $t];
 *          last if $t eq '}}' || $t eq '}}}' || $t eq '%}';
 *      }
 *  }
 *  if ((pos $src) < (length $src)) {
 *      push @token_list, [PLAIN, substr $src, pos $src];
 *  }
 *  push @token_list, [EOF, EOF];
 *
 * To write NFA's epsilon-closure, this implementation chooses
 * to read or to peek a character with the read_char flag.
 * For each timing before entering state routines,
 * when read_char is true a character reads in.
 * In the default, read_char flag turns off before each state
 * routines. 
 *
 * SV *source   inputs source scalar string.
 * SV *         returns list [[$token_kind, $token_value]].
 */
static
SV *
liq_tokenize(SV *source)
{
    U8 *csrc, *psrc, *esrc;
    STRLEN nsrc;
    UV c;
    IV u8src, state, read_char;
    AV *tokens, *token, *node;
    U8 *pplain, *eplain;
    U8 *pliteral, *eliteral;
    IV pos, plain_start, token_start; /* character position not byte index */
    IV token_kind, token_value;
    IV markup_b, markup_b_next;

#define LIQ_TOKENIZE_READ_AND_JUMP(j) read_char = 1; state = j
#define LIQ_TOKENIZE_PEEK_AND_JUMP(j) read_char = 0; state = j

#define LIQ_TOKENIZE_SPACE_STAR(j) \
    if (isSPACE_uni(c)) read_char = 1; else state = j

#define LIQ_TOKENIZE_IS_MARKUP(s,n) (esrc - psrc > n && strnEQ(psrc, s, n))

#define LIQ_TOKENIZE_MARKUP_AND_JUMP(n,k,j) \
    psrc += n; pos += n; read_char = 1; token_kind = k; state = j

#define LIQ_TOKENIZEx(k,x,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(k)); \
    av_push(token, x); \
    av_push(token, newSViv(c))

#define LIQ_TOKENIZEiv(k,v,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(k)); \
    av_push(token, newSViv(v)); \
    av_push(token, newSViv(c))

#define LIQ_TOKENIZE_CONSTx(x,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(LIQ_CONST)); \
    node = newAV(); \
    av_push(token, newRV_noinc((SV *)node)); \
    av_push(node, newSViv(LIQ_CONST)); \
    av_push(node, x); \
    av_push(token, newSViv(c))

#define LIQ_TOKENIZEpvnu8(k,b,d,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(k)); \
    node = newAV(); \
    av_push(token, newRV_noinc((SV *)node)); \
    av_push(node, newSViv(k)); \
    av_push(node, newSVpvn_utf8(b, d - b, u8src)); \
    av_push(token, newSViv(c))

#define LIQ_TOKENIZEpvn(k,b,d,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(k)); \
    node = newAV(); \
    av_push(token, newRV_noinc((SV *)node)); \
    av_push(node, newSViv(k)); \
    av_push(node, newSVpvn(b, d - b)); \
    av_push(token, newSViv(c))

#define LIQ_TOKENIZEav(k,c) \
    token = newAV(); \
    av_push(tokens, newRV_noinc((SV *)token)); \
    av_push(token, newSViv(k)); \
    node = newAV(); \
    av_push(token, newRV_noinc((SV *)node)); \
    av_push(node, newSViv(k)); \
    av_push(token, newSViv(c))

    /* relation ship between UV c variable and pointers and indexes.
     *
     *   c == utf8_to_uvchr_buf(csrc, esrc, &u8skip);
     *   psrc == csrc + u8skip;
     *
     * in perl
     *
     *   $c eq substr $source, $pos - 1, 1;
     */
    psrc = SvPV(source, nsrc);
    csrc = psrc;
    esrc = psrc + nsrc;
    u8src = SvUTF8(source);
    pos = 0;

    tokens = (AV *)sv_2mortal((SV *)newAV());

    pplain = eplain = psrc;
    plain_start = token_start = pos;
    token_kind = LIQ_EOF;

    LIQ_TOKENIZE_READ_AND_JUMP(0);
    while (1) {
        if (read_char) {
            read_char = 0;
            if (psrc >= esrc) {
                if (state == 0)
                    break;
                c = '\0';
            }
            else {
                csrc = psrc;
                if (! u8src) {
                    c = *psrc++;
                }
                else {
                    STRLEN u8skip;
                    c = utf8_to_uvchr_buf(psrc, esrc, &u8skip);
                    psrc += u8skip;
                }
                pos++;
            }
        }

        switch (state) {
        /* $src =~ m{\G(.*?)(?:(\{\{\{?)\s*|\{%\s*(\w+)\s*)}gcmsx */
        case 0:
            if (c == '{') {
                eplain = csrc;
                token_start = pos - 1;
                LIQ_TOKENIZE_READ_AND_JUMP(1);  /* (.*?)_\{ */
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(0);  /* (_.*?)\{ */
            }
            break;
        case 1:
            if (c == '{') {
                LIQ_TOKENIZE_READ_AND_JUMP(2);  /* (.*?)\{_\{ */
            }
            else if (c == '%') {
                markup_b = 1;
                LIQ_TOKENIZE_READ_AND_JUMP(3);  /* (.*?)\{_% */
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(0);
            }
            break;
        case 2:
            if (c == '{') {
                token_kind = LIQ_NOESCAPE;
                LIQ_TOKENIZE_READ_AND_JUMP(6);  /* (.*?)\{\{_\{ */
            }
            else {
                token_kind = LIQ_ESCAPE;
                LIQ_TOKENIZE_PEEK_AND_JUMP(6);  /* (.*?)\{\{_ */
            }
            break;
        case 3:
            LIQ_TOKENIZE_SPACE_STAR(4); /* (.*?)\{%_\s* */
            break;
        case 4:
            LIQ_TOKENIZE_PEEK_AND_JUMP(0);
            if (c >= 'a' && c <= 'z')  {
                markup_b_next = liq_markup_base[markup_b] + c - 'a' + 2;
                if (markup_b_next > 0 && markup_b_next < LIQ_TRIE_MARKUP_SIZE
                        && liq_markup_check[markup_b_next] == markup_b) {
                    markup_b = markup_b_next;
                    LIQ_TOKENIZE_READ_AND_JUMP(4);
                }
            }
            else if (! isALNUM_uni(c)) {
                markup_b_next = liq_markup_base[markup_b] + 1;
                if (markup_b_next > 0 && markup_b_next < LIQ_TRIE_MARKUP_SIZE
                        && liq_markup_check[markup_b_next] == markup_b) {
                    token_kind = liq_markup_base[markup_b_next];
                    LIQ_TOKENIZE_PEEK_AND_JUMP(5);
                }
            }
            break;
        case 5:
            LIQ_TOKENIZE_SPACE_STAR(6); /* (.*?)\{%\s*\w+_\s* */
            break;
        case 6:
            if (pplain < eplain) {
                LIQ_TOKENIZEpvnu8(LIQ_PLAIN, pplain, eplain, plain_start);
            }
            if (token_kind == LIQ_RAW || token_kind == LIQ_COMMENT) {
                LIQ_TOKENIZE_PEEK_AND_JUMP(29);
            }
            else if (token_kind == LIQ_CYCLE) {
                LIQ_TOKENIZE_PEEK_AND_JUMP(40);
            }
            else {
                LIQ_TOKENIZEiv(token_kind, token_kind, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);
            }
            break;

        /* $src =~ m{\G(?:$PUNCTTOK|$WORDTOK|$NUMTOK|$STRTOK)\s*}gcmsx */
        case 7:
            LIQ_TOKENIZE_SPACE_STAR(8);
            break;

        /* PUNCT */
        case 8:
            token_start = pos - 1;
            if (c == '}') {
                LIQ_TOKENIZE_READ_AND_JUMP(9);
            }
            else if (c == '%') {
                LIQ_TOKENIZE_READ_AND_JUMP(11);
            }
            else if (c == '=') {
                LIQ_TOKENIZE_READ_AND_JUMP(14);
            }
            else if (c == '!') {
                LIQ_TOKENIZE_READ_AND_JUMP(15);
            }
            else if (c == '<') {
                LIQ_TOKENIZE_READ_AND_JUMP(16);
            }
            else if (c == '>') {
                LIQ_TOKENIZE_READ_AND_JUMP(17);
            }
            else if (c == '.') {
                LIQ_TOKENIZE_READ_AND_JUMP(18);
            }
            else if (c == '\'') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(19);
            }
            else if (c == '"') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(20);
            }
            else if (c == '+' || c == '-') {
                pliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(21);
            }
            else if (isDIGIT(c)) {
                pliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(22);
            }
            else if (isALPHA_uni(c)) {
                pliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(13);
            }
            else if (c == ',') {
                LIQ_TOKENIZEiv(LIQ_COMMA, LIQ_COMMA, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == ':') {
                LIQ_TOKENIZEiv(LIQ_COLON, LIQ_COLON, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == '|') {
                LIQ_TOKENIZEiv(LIQ_FILTER, LIQ_FILTER, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == '[') {
                LIQ_TOKENIZEiv(LIQ_LSQUARE, LIQ_LSQUARE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == ']') {
                LIQ_TOKENIZEiv(LIQ_RSQUARE, LIQ_RSQUARE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == '(') {
                LIQ_TOKENIZEiv(LIQ_LPAREN, LIQ_LPAREN, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else if (c == ')') {
                LIQ_TOKENIZEiv(LIQ_RPAREN, LIQ_RPAREN, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else {
                goto unexpected;
            }
            break;

        /* R RR RR \}\}\}?|%\}\n? */
        case 9:
            if (c == '}') {
                LIQ_TOKENIZE_READ_AND_JUMP(10); /* \}_\} */
            }
            else {
                goto unexpected;
            }
            break;
        case 10:
            token_kind = c == '}' ? LIQ_RRR : LIQ_RR;
            LIQ_TOKENIZEiv(token_kind, token_kind, token_start);
            if (c != '\0' && token_kind == LIQ_RR) {
                pplain = csrc;
                plain_start = pos - 1;
            }
            else {
                pplain = psrc;
                plain_start = pos;
            }
            if (c == '}') {
                LIQ_TOKENIZE_READ_AND_JUMP(0);
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(0);
            }
            break;
        case 11:
            if (c != '}')
                goto unexpected;
            LIQ_TOKENIZEiv(LIQ_R, LIQ_R, token_start);
            pplain = psrc;
            plain_start = pos;
            LIQ_TOKENIZE_READ_AND_JUMP(12);     /* %_\} */
            break;
        case 12:
            if (c == '\n') {
                pplain = psrc;
                plain_start = pos;
                LIQ_TOKENIZE_READ_AND_JUMP(0);  /* %\}_\n */
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(0);
            }
            break;

        /* IDENT or KEYWORD or CONST [[:alpha:]][[:alnum:]_]* */
        case 13:
            if (c == '_' || (isALNUM_uni(c))) {
                LIQ_TOKENIZE_READ_AND_JUMP(13);
            }
            else {
                IV n;

                token_kind = LIQ_IDENT;         /* default */
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);  /* default */

                n = csrc - pliteral;
                switch (n) {
                case 2:
                    if (strnEQ(pliteral, "or", n))
                        token_kind = token_value = LIQ_OR;
                    else if (strnEQ(pliteral, "in", n))
                        token_kind = token_value = LIQ_IN;
                    break;
                case 3:
                    if (strnEQ(pliteral, "and", n))
                        token_kind = token_value = LIQ_AND;
                    else if (strnEQ(pliteral, "not", n))
                        token_kind = token_value = LIQ_NOT;
                    else if (strnEQ(pliteral, "for", n))
                        token_kind = token_value = LIQ_FOR;
                    else if (strnEQ(pliteral, "nil", n)) {
                        token_kind = LIQ_CONST;
                        LIQ_TOKENIZE_CONSTx(&PL_sv_undef, token_start);
                    }
                    break;
                case 4:
                    if (strnEQ(pliteral, "with", n))
                        token_kind = token_value = LIQ_WITH;
                    else if (strnEQ(pliteral, "null", n)) {
                        token_kind = LIQ_CONST;
                        LIQ_TOKENIZE_CONSTx(&PL_sv_undef, token_start);
                    }
                    else if (strnEQ(pliteral, "NULL", n)) {
                        token_kind = LIQ_CONST;
                        LIQ_TOKENIZE_CONSTx(&PL_sv_undef, token_start);
                    }
                    else if (strnEQ(pliteral, "true", n)) {
                        token_kind = LIQ_CONST;
                        LIQ_TOKENIZE_CONSTx(newSViv(1), token_start);
                    }
                    break;
                case 5:
                    if (strnEQ(pliteral, "false", n)) {
                        token_kind = LIQ_CONST;
                        LIQ_TOKENIZE_CONSTx(newSVpvn("", 0), token_start);
                    }
                    else if (strnEQ(pliteral, "empty", n)) {
                        if (c == '?') {
                            ++n;
                            LIQ_TOKENIZE_READ_AND_JUMP(7);
                        }
                        else {
                            token_kind = LIQ_CONST;
                            LIQ_TOKENIZE_CONSTx(
                                newRV_noinc((SV *)newAV()), token_start);
                        }
                    }
                    break;
                case 8:
                    if (strnEQ(pliteral, "continue", n))
                        token_kind = token_value = LIQ_CONTINUE;
                    else if (strnEQ(pliteral, "reversed", n))
                        token_kind = token_value = LIQ_REVERSED;
                    else if (strnEQ(pliteral, "contains", n)) {
                        token_kind = LIQ_CMP;
                        token_value = LIQ_CONTAINS;
                    }
                    break;
                }

                if (token_kind == LIQ_IDENT) {
                    LIQ_TOKENIZEx(LIQ_IDENT,
                        newSVpvn_utf8(pliteral, n, u8src), token_start);
                }
                else if (token_kind != LIQ_CONST) {
                    LIQ_TOKENIZEiv(token_kind, token_value, token_start);
                }
            }
            break;

        /* PUNCT PUNCT? */
        case 14:
            if (c == '=') {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_EQ, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* == */
            }
            else {
                LIQ_TOKENIZEiv(LIQ_EQUIV, LIQ_EQUIV, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);      /* = */
            }
            break;
        case 15:
            if (c == '=') {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_NE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* != */
            }
            else {
                LIQ_TOKENIZEiv(LIQ_NOT, LIQ_NOT, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);      /* ! */
            }
            break;
        case 16:
            if (c == '=') {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_LE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* <= */
            }
            else if (c == '>') {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_NE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* <> */
            }
            else {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_LT, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);      /* < */
            }
            break;
        case 17:
            if (c == '=') {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_GE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* >= */
            }
            else {
                LIQ_TOKENIZEiv(LIQ_CMP, LIQ_GT, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);      /* > */
            }
            break;
        case 18:
            if (c == '.') {
                LIQ_TOKENIZEiv(LIQ_RANGE, LIQ_RANGE, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);      /* [.][.] */
            }
            else {
                LIQ_TOKENIZEiv(LIQ_DOT, LIQ_DOT, token_start);
                LIQ_TOKENIZE_PEEK_AND_JUMP(7);      /* [.] */
            }
            break;

        /* STRING '(.*?)'|"(.*?)" */
        case 19:
            if (c == '\'') {            /* '(.*?)' */
                LIQ_TOKENIZEpvnu8(LIQ_STRING, pliteral, csrc, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(19);
            }
            break;
        case 20:
            if (c == '"') {            /* "(.*?)" */
                LIQ_TOKENIZEpvnu8(LIQ_STRING, pliteral, csrc, token_start);
                LIQ_TOKENIZE_READ_AND_JUMP(7);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(20);
            }
            break;

        /* NUMBER  [+-]?\d+(?:[.]\d+)?([eE][+-]?\d+)? */
        case 21:
            if (isDIGIT(c)) {
                LIQ_TOKENIZE_READ_AND_JUMP(22);         /* [+-]\d */
            }
            else {
                goto unexpected;
            }
            break;
        case 22:
            if (isDIGIT(c)) {
                LIQ_TOKENIZE_READ_AND_JUMP(22);
            }
            else if (c == '.') {
                if (*psrc == '.') {
                    LIQ_TOKENIZE_PEEK_AND_JUMP(28); /* [+-]?\d+ (?=[.][.]) */
                }
                else {
                    LIQ_TOKENIZE_READ_AND_JUMP(23); /* [+-]?\d+[.] */
                }
            }
            else if (c == 'e' || c == 'E') {
                LIQ_TOKENIZE_READ_AND_JUMP(25);     /* [+-]?\d+[eE] */
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(28);     /* [+-]?\d+ */
            }
            break;
        case 23:
            if (isDIGIT(c)) {
                LIQ_TOKENIZE_READ_AND_JUMP(24);     /* [+-]?\d+[.]\d */
            }
            else {
                goto unexpected;
            }
            break;
        case 24:
            if (isDIGIT(c)) {
                LIQ_TOKENIZE_READ_AND_JUMP(24);
            }
            else if (c == 'e' || c == 'E') {
                LIQ_TOKENIZE_READ_AND_JUMP(25);     /* [+-]?\d+[.]\d+[eE] */
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(28);     /* [+-]?\d+[.]\d+ */
            }
            break;
        case 25:                                    
            if (c == '+' || c == '-') {
                LIQ_TOKENIZE_READ_AND_JUMP(26); /* [+-]?\d+(?:[.]\d+)?[eE][+-] */
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(26); /* [+-]?\d+(?:[.]\d+)?[eE] */
            }
            break;
        case 26:
            if (isDIGIT(c)) {   /* [+-]?\d+(?:[.]\d+)?[eE][+-]?\d */
                LIQ_TOKENIZE_READ_AND_JUMP(27);
            }
            else {
                goto unexpected;
            }
            break;
        case 27:
            if (isDIGIT(c)) {           /* [+-]?\d+(?:[.]\d+)?[eE][+-]?\d\d* */
                LIQ_TOKENIZE_READ_AND_JUMP(27);
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(28);
            }
            break;
        case 28:
            LIQ_TOKENIZEpvn(LIQ_NUMBER, pliteral, csrc, token_start);
            LIQ_TOKENIZE_PEEK_AND_JUMP(7);
            break;

        /* \{%\s*raw\s*_%\}\n?(.*?)\{%\s*endraw\s*%\}\n? */
        /* \{%\s*comment\s*_%\}.*?\{%\s*endcomment\s*%\}\n? */
        case 29:
            if (isSPACE_uni(c)) {
                LIQ_TOKENIZE_READ_AND_JUMP(29);
            }
            else if (c == '%') {
                LIQ_TOKENIZE_READ_AND_JUMP(30);
            }
            else {
                goto unexpected;
            }
            break;
        case 30:
            /* \{%\s*raw\s*%_\}\n?(.*?)\{%\s*endraw\s*%\}\n? */
            /* \{%\s*comment\s*%_\}.*?\{%\s*endcomment\s*%\}\n? */
            if (c == '}') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(31);
            }
            else {
                goto unexpected;
            }
            break;
        case 31:
            /* \{%\s*raw\s*%\}_\n?(.*?)\{%\s*endraw\s*%\}\n? */
            /* \{%\s*comment\s*%\}_\n?.*?\{%\s*endcomment\s*%\}\n? */
            if (c == '\n') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(32);
            }
            break;
        case 32:
            /* \{%\s*raw\s*%\}\n?(_.*?)\{%\s*endraw\s*%\}\n? */
            /* \{%\s*comment\s*%\}\n?_.*?\{%\s*endcomment\s*%\}\n? */
            if (c == '{') {
                LIQ_TOKENIZE_READ_AND_JUMP(33);
            }
            else if (c != '\0') {
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            else {
                goto unexpected;
            }
            break;
        case 33:
            /* \{%\s*raw\s*%\}\n?(.*?)\{_%\s*endraw\s*%\}\n? */
            /* \{%\s*comment\s*%\}\n?.*?\{_%\s*endcomment\s*%\}\n? */
            if (c == '%') {
                eliteral = psrc - 2;
                LIQ_TOKENIZE_READ_AND_JUMP(34);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            break;
        case 34:
            LIQ_TOKENIZE_SPACE_STAR(35);
            break;
        case 35:
            /* \{%\s*raw\s*%\}\n?(.*?)\{%\s*_endraw\s*%\}\n? */
            /* \{%\s*comment\s*%\}\n?.*?\{%\s*_endcomment\s*%\}\n? */
            if (token_kind == LIQ_RAW
                && c == 'e' && (LIQ_TOKENIZE_IS_MARKUP("ndraw", 5))
            ) {
                LIQ_TOKENIZE_MARKUP_AND_JUMP(5, LIQ_RAW, 36);
            }
            else if (token_kind == LIQ_COMMENT
                && c == 'e' && (LIQ_TOKENIZE_IS_MARKUP("ndcomment", 9))
            ) {
                LIQ_TOKENIZE_MARKUP_AND_JUMP(9, LIQ_COMMENT, 36);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            break;
        case 36:
            LIQ_TOKENIZE_SPACE_STAR(37);
            break;
        case 37:
            /* \{%\s*raw\s*%\}\n?(.*?)\{%\s*endraw\s*_%\}\n? */
            /* \{%\s*comment\s*%\}\n?.*?\{%\s*endcomment\s*_%\}\n? */
            if (c == '%') {
                LIQ_TOKENIZE_READ_AND_JUMP(38);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            break;
        case 38:
            /* \{%\s*raw\s*%\}\n?(.*?)\{%\s*endraw\s*%_\}\n? */
            /* \{%\s*comment\s*%\}\n?.*?\{%\s*endcomment\s*%_\}\n? */
            if (c == '}') {
                if (token_kind == LIQ_RAW && pliteral < eliteral) {
                    LIQ_TOKENIZEpvnu8(LIQ_PLAIN, pliteral, eliteral, token_start);
                }
                pplain = psrc;
                plain_start = pos;
                LIQ_TOKENIZE_READ_AND_JUMP(39);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(32);
            }
            break;
        case 39:
            /* \{%\s*raw\s*%\}\n?(.*?)\{%\s*endraw\s*%\}_\n? */
            /* \{%\s*comment\s*%\}\n?.*?\{%\s*endcomment\s*%\}_\n? */
            if (c == '\n') {
                pplain = psrc;
                plain_start = pos;
                LIQ_TOKENIZE_READ_AND_JUMP(0);
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(0);
            }
            break;

        /* CYCLEVALUE  ".*?" | '.*?' | \w[\w-]*
         * \{%\s*cycle\s*_(?:$CYCLEVALUE\s*:\s*)?
         *                $CYCLEVALUE\s*(?:,\s*$CYCLEVALUE\s*)*%\}\n?
         */
        case 40:
            /* node = (AV *)(cycle node new) */
            LIQ_TOKENIZEav(LIQ_CYCLE, token_start);
            if (c == '\'') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(41);
            }
            else if (c == '"') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(42);
            }
            else if (c == '_' || (isALNUM_uni(c))) {
                pliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(43);
            }
            else {
                goto unexpected;
            }
            break;
        case 41:
            /* \{%\s*cycle\s*(?:'_.*?'\s*:\s*)?
             *                '_.*?'\s*(?:,\s*$CYCLEVALUE\s*)*%\}\n? */
           if (c == '\'') {
                eliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(44);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(41);
            }
            break;
        case 42:
            /* \{%\s*cycle\s*(?:"_.*?"\s*:\s*)?
             *                "_.*?"\s*(?:,\s*$CYCLEVALUE\s*)*%\}\n? */
            if (c == '"') {
                eliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(44);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(42);
            }
            break;
        case 43:
            /* \{%\s*cycle\s*(?:\w_[\w-]*\s*:\s*)?
             *                \w_[\w-]*\s*(?:,\s*$CYCLEVALUE\s*)*%\}\n? */
            if (c == '-' || c == '_' || (isALNUM_uni(c))) {
                LIQ_TOKENIZE_READ_AND_JUMP(43);
            }
            else {
                eliteral = csrc;
                LIQ_TOKENIZE_PEEK_AND_JUMP(44);
            }
            break;
        case 44:
            LIQ_TOKENIZE_SPACE_STAR(45);
            break;
        case 45:
            if (c == ':') {
                /* \{%\s*cycle\s*$CYCLEVALUE\s*_:\s*
                 *               $CYCLEVALUE\s*(?:,\s*$CYCLEVALUE\s*)*%\}\n? */
                av_push(node, newSVpvn_utf8(pliteral, eliteral - pliteral, u8src));
                LIQ_TOKENIZE_READ_AND_JUMP(46);
            }
            else {
                /* \{%\s*cycle\s*
                 *               $CYCLEVALUE\s*_(?:,\s*$CYCLEVALUE\s*)*%\}\n? */
                av_push(node, newSVpv("", 0));
                av_push(node, newSVpvn_utf8(pliteral, eliteral - pliteral, u8src));
                LIQ_TOKENIZE_PEEK_AND_JUMP(52);
            }
            break;
        case 46:
            LIQ_TOKENIZE_SPACE_STAR(47);
            break;
        case 47:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                _$CYCLEVALUE\s*(?:,\s*_$CYCLEVALUE\s*)*%\}\n? */
            if (c == '\'') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(48);
            }
            else if (c == '"') {
                pliteral = psrc;
                LIQ_TOKENIZE_READ_AND_JUMP(49);
            }
            else if (c == '_' || (isALNUM_uni(c))) {
                pliteral = csrc;
                LIQ_TOKENIZE_READ_AND_JUMP(50);
            }
            else {
                goto unexpected;
            }
            break;
        case 48:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                '_.*?'\s*(?:,\s*'_.*?'\s*)*%\}\n? */
            if (c == '\'') {
                av_push(node, newSVpvn_utf8(pliteral, csrc - pliteral, u8src));
                LIQ_TOKENIZE_READ_AND_JUMP(51);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(48);
            }
            break;
        case 49:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                "_.*?"\s*(?:,\s*"_.*?"\s*)*%\}\n? */
            if (c == '"') {
                av_push(node, newSVpvn_utf8(pliteral, csrc - pliteral, u8src));
                LIQ_TOKENIZE_READ_AND_JUMP(51);
            }
            else {
                LIQ_TOKENIZE_READ_AND_JUMP(49);
            }
            break;
        case 50:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                \w_[\w-]*\s*(?:,\s*\w_[\w-]*\s*)*%\}\n? */
            if (c == '-' || c == '_' || (isALNUM_uni(c))) {
                LIQ_TOKENIZE_READ_AND_JUMP(50);
            }
            else {
                av_push(node, newSVpvn_utf8(pliteral, csrc - pliteral, u8src));
                LIQ_TOKENIZE_PEEK_AND_JUMP(51);
            }
            break;
        case 51:
            LIQ_TOKENIZE_SPACE_STAR(52);
            break;
        case 52:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                $CYCLEVALUE\s*(?:_,\s*$CYCLEVALUE\s*)*%\}\n? */
            if (c == ',') {
                LIQ_TOKENIZE_READ_AND_JUMP(46);
            }
            else if (c == '%') {
                LIQ_TOKENIZE_READ_AND_JUMP(53);
            }
            else {
                goto unexpected;
            }
            break;
        case 53:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                $CYCLEVALUE\s*(?:,\s*$CYCLEVALUE\s*)*%_\}\n? */
            if (c != '}')
                goto unexpected;
            liq_tokenize_cycle_group(node, u8src);
            pplain = psrc;
            plain_start = pos;
            LIQ_TOKENIZE_READ_AND_JUMP(54);
            break;
        case 54:
            /* \{%\s*cycle\s*(?:$CYCLEVALUE\s*:\s*)?
             *                $CYCLEVALUE\s*(?:,\s*$CYCLEVALUE\s*)*%\}_\n? */
            if (c == '\n') {
                pplain = psrc;
                plain_start = pos;
                LIQ_TOKENIZE_READ_AND_JUMP(0);
            }
            else {
                LIQ_TOKENIZE_PEEK_AND_JUMP(0);
            }
            break;
        }
    }

    /* if ((pos $src) < (length $src)) {
     *    push @token_list, [PLAIN, substr $src, pos $src];
     * }
     */
    if (esrc > pplain) {
        LIQ_TOKENIZEpvnu8(LIQ_PLAIN, pplain, esrc, plain_start);
    }
    /* push @token_list, [EOF, EOF]; */
    LIQ_TOKENIZEiv(LIQ_EOF, LIQ_EOF, pos);

    return (SV *)newRV_inc((SV *)tokens);

unexpected:
    av_clear(tokens);
    LIQ_TOKENIZEx(LIQ_ERROR, newSVpv("SyntaxError: scanner.", 0), token_start);

    return (SV *)newRV_inc((SV *)tokens);
}

/**
 * takes a part of PV string from character position fromsrc
 * following character lengths n.
 * When source SV gets the UTF-8 encoding,
 * both the character position and charcter length mean
 * not byte's them but multi-byte character's them.
 * When source SV gets the LATIN1 encoding or bytes buffer,
 * both of them mean just byte's them.
 *
 *  SV *source  a scalar instance as SVPV
 *  IV frompart  character position for a part of string.
 *  IV npart character length for a part of string.
 *
 *  SV *        new string scalar (REFCNT = 1, not mortal)
 */
static
SV *
liq_substr(SV *source, IV frompart, IV npart)
{
    IV u8src, topart;
    U8 *psrc, *qsrc, *esrc;
    STRLEN nsrc, pos, u8skip;

    topart = frompart + npart;
    u8src = SvUTF8(source);
    psrc = SvPV(source, nsrc);
    esrc = psrc + nsrc;

    if (! u8src)
        return newSVpvn(psrc + frompart, npart);

    for (pos = 0; pos < frompart && psrc < esrc; ++pos) {
        u8skip = UTF8SKIP(psrc);
        psrc += u8skip;
    }

    qsrc = psrc;
    for (; pos < topart && qsrc < esrc; ++pos) {
        u8skip = UTF8SKIP(qsrc);
        qsrc += u8skip;
    }
    return newSVpvn_utf8(psrc, qsrc - psrc, u8src);
}

/**
 * creates a new string scalar from a given scalar source
 * triming white spaces in it. This function equivalents
 * from Perl 5.16 replacements.
 *
 *      (my $result = $source) =~ s/\s+//ugmsx;
 *
 * SV* source   a scalar instance as SVPV
 *
 * SV *        new string scalar (REFCNT = 1, not mortal)
 */
static
SV *
liq_trim_spaces(SV *source)
{
    SV *result;
    IV u8src;
    UV c;
    U8 *psrc, *esrc;
    STRLEN nsrc, u8skip;

    u8src = SvUTF8(source);
    psrc = SvPV(source, nsrc);
    esrc = psrc + nsrc;

    result = newSVpvn_utf8("", 0, u8src);
    while (psrc < esrc) {
        c = utf8_to_uvchr_buf(psrc, esrc, &u8skip);
        if (! isSPACE_uni(c))
            sv_catpvn(result, psrc, u8skip);
        psrc += u8skip;
    }
    return result;
}

/**
 * print stack elements of parser for trace output.
 *
 *  AV *stack   array of SVIV.
 */
static
void
liq_print_stack(AV *stack)
{
    SV **item;
    IV i, n;

    n = av_len(stack) + 1;
    PerlIO_printf(PerlIO_stdout(), "[");
    for (i = 0; i < n; ++i) {
        item = av_fetch(stack, i, 0);
        if (i > 0)
            PerlIO_printf(PerlIO_stdout(), ", ");
        PerlIO_printf(PerlIO_stdout(), "%d", (int)SvIV(*item));
    }
    PerlIO_printf(PerlIO_stdout(), "]");
}

/**
 * unshift IV symbols into parser continuation list.
 *
 *  AV *stack   continuation list array of SVIV.
 *  IV n        number of symbols
 *  IV ...      va_list of symbols
 */
static
void
liq_unshift_symbols(AV *stack, IV n, ...)
{
    va_list args;
    IV i, symbol;
    
    av_unshift(stack, n);
    va_start(args, n);
    for (i = 0; i < n; ++i) {
        symbol = (IV)(va_arg(args, int));
        av_store(stack, i, newSViv(symbol));
    }
    va_end(args);
}

MODULE = Text::Liq::XS		PACKAGE = Text::Liq::XS		

SV*
xtokenize(SV *src)
    PROTOTYPE: DISABLE
    CODE:
        RETVAL = liq_tokenize(src);
    OUTPUT:
        RETVAL

SV*
xparse(SV *source, SV* rv_token_list)
    PROTOTYPE: DISABLE
    CODE:
        RETVAL = liq_parse(source, rv_token_list);
    OUTPUT:
        RETVAL

