/*
 * Redistribution and use in source and binary forms, with
 * or without modification, are permitted provided that the
 * following conditions are met:
 *
 * 1. Redistributions of source code must retain this list
 *    of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce this
 *    list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the
 *    distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
 * CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
%{
#include <config.h>
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "file.h"
#include "list.h"
#include "program.h"
#include "thanm.h"
#include "value.h"

/* Bison things. */
void yyerror(const parser_state_t*, const char*, ...);
int yylex(void);
extern FILE* yyin;

typedef struct prop_list_entry_value_t {
    int type;
    union {
        int S;
        float f;
        char* t;
        list_t* l;
    } val;
} prop_list_entry_value_t;

typedef struct prop_list_entry_t {
    char* key;
    /* Not using value_t due to the need of list_t. */
    prop_list_entry_value_t* value;
} prop_list_entry_t;

/* Returns the entry with the given key, or NULL if it's not found. */
static prop_list_entry_t* prop_list_find(list_t* list, const char* key);

/* Recursively frees the property list content. Does not free the list itself. */
static void prop_list_free_nodes(list_t* list);

/* Creates a new instruction. */
static thanm_instr_t* instr_new(parser_state_t* state, uint16_t id, list_t* params);

/* Returns instruction number given an identifier, or -1 if it's not an instruction. */
static int identifier_instr(char* ident);

/* Searches for a global definition with a given name. */
static global_t* global_find(parser_state_t* state, const char* name);

/* Creates a copy of the given param. */
static thanm_param_t* param_copy(thanm_param_t* param);

%}

%define parse.error verbose
%locations
%parse-param {parser_state_t* state}

%union {
    /* Token types (from flex) */
    int integer;
    float floating;
    char* string;

    /* Internal types */
    struct thanm_param_t* param;
    struct list_t* list;
    struct prop_list_entry_t* prop_list_entry;
    struct prop_list_entry_value_t* prop_list_entry_value;
}

%token <floating> FLOATING "floating"
%token <integer> INTEGER "integer"
%token <string> IDENTIFIER "identifier"
%token <string> TEXT "text"
%token <string> DIRECTIVE "directive"

%token EQUALS "="
%token PLUS "+"
%token COMMA ","
%token COLON ":"
%token SEMICOLON ";"
%token SQUARE_OPEN "["
%token SQUARE_CLOSE "]"
%token BRACE_OPEN "{"
%token BRACE_CLOSE "}"
%token PARENTHESIS_OPEN "("
%token PARENTHESIS_CLOSE ")"
%token MODULO "%"
%token DOLLAR "$"
%token ENTRY "entry"
%token SCRIPT "script"
%token GLOBAL "global"
%token TIMEOF "timeof"
%token OFFSETOF "offsetof"
%token SCRIPTOF "scriptof"
%token SPRITEOF "spriteof"

%token ILLEGAL_TOKEN "invalid token"
%token END_OF_FILE 0 "end of file"

%type <integer> SomethingOf
%type <string> TextLike
%type <param> ParameterLiteral
%type <param> ParameterOther
%type <param> Parameter
%type <list> Properties
%type <list> PropertyList
%type <list> Parameters
%type <list> ParametersList
%type <prop_list_entry> PropertyListEntry
%type <prop_list_entry_value> PropertyListValue

%%

Statements:
    %empty
    | Statements Statement

Statement:
    Entry
    | Script
    | Directive
    | "global" IDENTIFIER[name] "=" Parameter[param] ";" {
        global_t* global = (global_t*)malloc(sizeof(global_t));
        global->name = $name;
        global->param = $param;
        list_prepend_new(&state->globals, global);
    }

Entry:
    "entry" IDENTIFIER[entry_name] "{" Properties[prop_list] "}" {
        anm_entry_t* entry = (anm_entry_t*)malloc(sizeof(anm_entry_t));
        entry->header = (anm_header06_t*)calloc(1, sizeof(anm_header06_t));
        entry->thtx = (thtx_header_t*)calloc(1, sizeof(thtx_header_t));

        entry->thtx->magic[0] = 'T';
        entry->thtx->magic[1] = 'H';
        entry->thtx->magic[2] = 'T';
        entry->thtx->magic[3] = 'X';

        entry->name = NULL;
        entry->name2 = NULL;
        list_init(&entry->sprites);
        list_init(&entry->scripts);
        entry->data = NULL;

        prop_list_entry_t* prop;
        #define REQUIRE(x, y, l) { \
            prop = prop_list_find(l, x); \
            if (prop == NULL)  { \
                yyerror(state, "missing entry property: '" x "'"); \
                return 1; \
            } else if (prop->value->type != y) { \
                yyerror(state, "wrong value type for entry property: '" x "'"); \
                return 1; \
            } \
        }

        #define OPTIONAL(x, y, l) { \
            prop = prop_list_find(l, x); \
            if (prop && prop->value->type != y) { \
                yyerror(state, "wrong value type for entry property: '" x "'"); \
                return 1; \
            } \
        }

        if (state->default_version == -1)
            REQUIRE("version", 'S', $prop_list)
        else
            OPTIONAL("version", 'S', $prop_list)

        entry->header->version = prop ? prop->value->val.S : state->default_version;

        REQUIRE("name", 't', $prop_list);
        entry->name = strdup(prop->value->val.t);

        OPTIONAL("name2", 't', $prop_list);
        if (prop) entry->name2 = strdup(prop->value->val.t);

        OPTIONAL("format", 'S', $prop_list);
        entry->header->format = prop ? prop->value->val.S : 1;

        OPTIONAL("width", 'S', $prop_list);
        entry->header->w = prop ? prop->value->val.S : DEFAULTVAL;

        OPTIONAL("height", 'S', $prop_list);
        entry->header->h = prop ? prop->value->val.S : DEFAULTVAL;

        OPTIONAL("xOffset", 'S', $prop_list);
        entry->header->x = prop ? prop->value->val.S : 0;

        OPTIONAL("yOffset", 'S', $prop_list);
        entry->header->y = prop ? prop->value->val.S : 0;

        OPTIONAL("colorKey", 'S', $prop_list);
        entry->header->colorkey = prop ? prop->value->val.S : 0;

        OPTIONAL("memoryPriority", 'S', $prop_list);
        entry->header->memorypriority =
            prop ? prop->value->val.S : (entry->header->version >= 1 ? 10 : 0);

        OPTIONAL("lowResScale", 'S', $prop_list);
        entry->header->lowresscale = prop ? prop->value->val.S : 0;

        OPTIONAL("hasData", 'S', $prop_list);
        entry->header->hasdata = prop ? prop->value->val.S : 1;

        if (entry->header->hasdata) {
            OPTIONAL("THTXSize", 'S', $prop_list);
            entry->thtx->size = prop ? prop->value->val.S : DEFAULTVAL;

            OPTIONAL("THTXFormat", 'S', $prop_list);
            entry->thtx->format = prop ? prop->value->val.S : DEFAULTVAL;

            OPTIONAL("THTXWidth", 'S', $prop_list);
            entry->thtx->w = prop ? prop->value->val.S : DEFAULTVAL;
        
            OPTIONAL("THTXHeight", 'S', $prop_list);
            entry->thtx->h = prop ? prop->value->val.S : DEFAULTVAL;

            OPTIONAL("THTXZero", 'S', $prop_list);
            entry->thtx->zero = prop ? prop->value->val.S : 0;
        }

        OPTIONAL("sprites", 'l', $prop_list);
        if (prop) {
            list_for_each(prop->value->val.l, prop) {
                if (prop->value->type != 'l') {
                    yyerror(state, "%s: expected property list for sprite definition, got a single value instead", prop->key);
                    continue;
                }
                list_t* inner_list = prop->value->val.l;
                char* name = prop->key;

                sprite_t* sprite = (sprite_t*)malloc(sizeof(sprite_t));

                OPTIONAL("id", 'S', inner_list);
                if (prop) state->sprite_id = prop->value->val.S;
                sprite->id = state->sprite_id++;

                REQUIRE("x", 'S', inner_list);
                sprite->x = (float)prop->value->val.S;
                REQUIRE("y", 'S', inner_list);
                sprite->y = (float)prop->value->val.S;
                REQUIRE("w", 'S', inner_list);
                sprite->w = (float)prop->value->val.S;
                REQUIRE("h", 'S', inner_list);
                sprite->h = (float)prop->value->val.S;
                list_append_new(&entry->sprites, sprite);

                symbol_id_pair_t* symbol = (symbol_id_pair_t*)malloc(sizeof(symbol_id_pair_t));
                symbol->id = sprite->id;
                symbol->name = strdup(name);
                list_append_new(&state->sprite_names, symbol);
            }
        }

        #undef OPTIONAL
        #undef REQUIRE

        free($prop_list);
        free($entry_name);
        list_append_new(&state->entries, entry);
        state->current_entry = entry;
    }

Properties:
    %empty {
        $$ = list_new();
    }
    | PropertyList[list] {
        $$ = $list;
    }

PropertyList:
    PropertyListEntry[prop] {
        $$ = list_new();
        list_append_new($$, $prop);
    }
    | PropertyList[list] "," PropertyListEntry[prop] {
        list_append_new($list, $prop);
    }

PropertyListEntry:
    IDENTIFIER[key] ":" PropertyListValue[val] {
        $$ = (prop_list_entry_t*)malloc(sizeof(prop_list_entry_t));
        $$->key = $key;
        $$->value = $val;
    }

PropertyListValue:
    INTEGER {
        $$ = (prop_list_entry_value_t*)malloc(sizeof(prop_list_entry_value_t));
        $$->type = 'S';
        $$->val.S = $1;
    }
    | FLOATING {
        $$ = (prop_list_entry_value_t*)malloc(sizeof(prop_list_entry_value_t));
        $$->type = 'f';
        $$->val.f = $1;
    }
    | TEXT {
        $$ = (prop_list_entry_value_t*)malloc(sizeof(prop_list_entry_value_t));
        $$->type = 't';
        $$->val.t = $1;
    }
    | "{" Properties "}" {
        $$ = (prop_list_entry_value_t*)malloc(sizeof(prop_list_entry_value_t));
        $$->type = 'l';
        $$->val.l = $2;
    }
    | IDENTIFIER {
        $$ = (prop_list_entry_value_t*)malloc(sizeof(prop_list_entry_value_t));
        global_t* global = global_find(state, $1);
        if (global == NULL) {
            yyerror(state, "global definition not found: %s", $1);
            $$->type = 'S';
            $$->val.S = 0;
        } else {
            if (global->param->is_var)
                yyerror(state, "variables are not acceptable in parameter lists"
                    "(through global definition: %s)", $1);
            switch(global->param->type) {
                case 'S':
                    $$->type = 'S';
                    $$->val.S = global->param->val->val.S;
                    break;
                case 'f':
                    $$->type = 'f';
                    $$->val.f = global->param->val->val.f;
                    break;
                case 'z':
                    $$->type = 't';
                    $$->val.t = strdup(global->param->val->val.z);
                    break;
                default:
                    $$->type = 'S';
                    $$->val.S = 0;
                    yyerror(state, "parameter type '%c' is not acceptable in parameter lists"
                        "(through global definition: %s)", global->param->type, $1);
                    break;
            }
        }
    }

Script:
    "script" ScriptOptionalId IDENTIFIER[name] {
        if (state->current_entry == NULL) {
            yyerror(state, "an entry is required before a script");
            return 1;
        }
        anm_script_t* script = (anm_script_t*)malloc(sizeof(anm_script_t));
        list_init(&script->instrs);
        list_init(&script->raw_instrs);
        list_init(&script->labels);
        script->offset = malloc(sizeof(*script->offset));
        script->offset->id = state->script_id++;

        symbol_id_pair_t* symbol = (symbol_id_pair_t*)malloc(sizeof(symbol_id_pair_t));
        symbol->id = script->offset->id;
        symbol->name = $name;
        list_append_new(&state->script_names, symbol);

        list_append_new(&state->current_entry->scripts, script);
        state->current_script = script;
        state->offset = 0;
        state->time = 0;
    } "{" ScriptStatements "}" {
        state->current_script= NULL;
    }

ScriptOptionalId:
    %empty
    | INTEGER[id] {
        state->script_id = $id;
    }

ScriptStatements:
    %empty
    | ScriptStatements ScriptStatement

ScriptStatement:
    INTEGER[time] ":" {
        state->time = $time;
    }
    | "+" INTEGER[time] ":" {
        state->time += $time;
    }
    | IDENTIFIER[name] ":" {
        if (label_find(state->current_script, $name) != NULL) {
            yyerror(state, "duplicate label: %s", $name);
        }
        label_t* label = (label_t*)malloc(sizeof(label_t));
        label->name = $name;
        label->offset = state->offset;
        label->time = state->time;
        list_append_new(&state->current_script->labels, label);
    }
    | IDENTIFIER[ident] "(" Parameters[params] ")" ";" {
        int id = identifier_instr($ident);
        if (id == -1) {
            yyerror(state, "unknown mnemonic: %s", $ident);
            return 1;
        }
        thanm_instr_t* instr = instr_new(state, id, $params);
        list_append_new(&state->current_script->instrs, instr);

        free($ident);
    }

Parameters:
    %empty {
        $$ = list_new();
    }
    | ParametersList {
        $$ = $1;
    }

ParametersList:
    Parameter[param] {
        $$ = list_new();
        list_append_new($$, $param);
    }
    | ParametersList[list] "," Parameter[param] {
        list_append_new($list, $param);
    }

Parameter:
    ParameterLiteral {
        $$ = $1;
    }
    | ParameterOther {
        $$ = $1;
    }

ParameterLiteral:
    INTEGER {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'S';
        val->val.S = $1;
        thanm_param_t* param = thanm_param_new('S');
        param->val = val;
        $$ = param;
    }
    | FLOATING {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'f';
        val->val.f = $1;
        thanm_param_t* param = thanm_param_new('f');
        param->val = val;
        $$ = param;
    }
    | TEXT {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'z';
        val->val.z = $1;
        thanm_param_t* param = thanm_param_new('z');
        param->val = val;
        $$ = param;
    }

ParameterOther:
    "[" INTEGER "]" {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'S';
        val->val.S = $2;
        thanm_param_t* param = thanm_param_new('S');
        param->is_var = 1;
        param->val = val;
        $$ = param;
    }
    | "[" FLOATING "]" {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'f';
        val->val.f = $2;
        thanm_param_t* param = thanm_param_new('f');
        param->is_var = 1;
        param->val = val;
        $$ = param;
    }
    | "$" IDENTIFIER {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'S';
        thanm_param_t* param = thanm_param_new('S');
        param->is_var = 1;
        param->val = val;

        seqmap_entry_t* ent = seqmap_find(g_anmmap->gvar_names, $2);
        if (ent == NULL) {
            yyerror(state, "unknown variable: %s", $2);
            param->val->val.S = 0;
        } else {
            param->val->val.S = ent->key;
        }
        free($2);
        $$ = param;
    }
    | "%" IDENTIFIER {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'f';
        thanm_param_t* param = thanm_param_new('f');
        param->is_var = 1;
        param->val = val;

        seqmap_entry_t* ent = seqmap_find(g_anmmap->gvar_names, $2);
        if (ent == NULL) {
            yyerror(state, "unknown variable: %s", $2);
            param->val->val.f = 0.0f;
        } else {
            param->val->val.f = (float)ent->key;
        }
        free($2);
        $$ = param;
    }
    | IDENTIFIER {
        /* First, check for variables and globaldefs.
         * If it's neither, then simply make it a string param that
         * will be evaluated based on context (what format the instr expects) */
        global_t* global = global_find(state, $1);
        if (global) {
            $$ = param_copy(global->param);
        } else {
            value_t* val = (value_t*)malloc(sizeof(value_t));
            thanm_param_t* param;
            seqmap_entry_t* ent = seqmap_find(g_anmmap->gvar_names, $1);
            if (ent) {
                int id = ent->key;
                ent = seqmap_get(g_anmmap->gvar_types, id);
                if (ent == NULL) {
                    /* Unknown type */
                    yyerror(state, "type of variable is unknown: %s", $1);
                    val->type = 'S';
                    val->val.S = 0;
                    param = thanm_param_new('S');
                    param->val = val;
                } else {
                    val->type = ent->value[0] == '$' ? 'S' : 'f';
                    if (val->type == 'S')
                        val->val.S = id;
                    else
                        val->val.f = (float)id;
                    
                    param = thanm_param_new(val->type);
                    param->is_var = 1;
                    param->val = val;
                }
                free($1);
            } else {
                val->type = 'z';
                val->val.z = $1;
                param = thanm_param_new('z');
                param->val = val;
            }
            $$ = param;
        }
    }
    | SomethingOf[type] "(" IDENTIFIER[label] ")" {
        value_t* val = (value_t*)malloc(sizeof(value_t));
        val->type = 'z';
        val->val.z = $label;
        thanm_param_t* param = thanm_param_new($type);
        param->val = val;
        $$ = param;
    }

SomethingOf:
    "timeof" {
        $$ = 't';
    }
    | "offsetof" {
        $$ = 'o';
    }
    | "scriptof" {
        $$ = 'N';
    }
    | "spriteof" {
        $$ = 'n';
    }

TextLike:
    TEXT {
        $$ = $1;
    }
    | INTEGER {
        char buf[32];
        snprintf(buf, sizeof(buf), "%d", $1);
        $$ = strdup(buf);
    }
    | FLOATING {
        char buf[32];
        snprintf(buf, sizeof(buf), "%f", $1);
        $$ = strdup(buf);
    }

Directive:
    DIRECTIVE[type] TextLike[arg] {
        if (strcmp($type, "version") == 0) {
            uint32_t ver = strtoul($arg, NULL, 10);
            state->default_version = ver;
        } else {
            yyerror(state, "unknown directive: %s", $type);
        }
        free($type);
        free($arg);
    }

%%

static prop_list_entry_t* 
prop_list_find(
    list_t* list, 
    const char* key
) {
    prop_list_entry_t* entry;
    list_for_each(list, entry) {
        if (strcmp(entry->key, key) == 0)
            return entry;
    }
    return NULL;
}

static void
prop_list_free_nodes(
    list_t* list
) {
    prop_list_entry_t* entry;
    list_for_each(list, entry) {
        if (entry->value->type == 't') {
            free(entry->value->val.t);
        } else if (entry->value->type == 'l') {
            prop_list_free_nodes(entry->value->val.l);
            free(entry->value->val.l);
        }
        free(entry->value);
        free(entry->key);
        free(entry);
        list_free_nodes(entry->value->val.l);
    }
}

static void
instr_check_types(
    parser_state_t* state,
    thanm_instr_t* instr
) {
    const id_format_pair_t* formats = anm_get_formats(state->current_entry->header->version);
    const char* format = find_format(formats, instr->id);
    if (format == NULL) {
        state->was_error = 1;
        yyerror(state, "opcode %d is not known to exist in version %d", instr->id, state->current_entry->header->version);
        return;
    }
    thanm_instr_t* param;
    size_t i = 0;
    list_for_each(&instr->params, param) {
        char c = format[i];
        if (c == '\0') {
            state->was_error = 1;
            yyerror(state, "too many parameters for opcode %d", instr->id);
            break;
        }
        if (c == 'S') {
            /* Allow types that get converted to integers later for integer formats. */
            if (param->type == 't' || param->type == 'o' || param->type == 'N' || param->type == 'n')
                c = param->type;
        } else if (c == 'n' || c == 'N' || c == 'o' || c == 't') {
            /* This is to tell the anm_serialize_instr function what it should do
             * with the string value of the param, based on the instruction format. */
            if (param->type == 'z')
                param->type = c;
            else if (param->type == 'S') /* Allow numbers for things that get converted to numbers anyway. */
                c = param->type;
        }
        
        if (param->type != c) {
            state->was_error = 1;
            yyerror(state, "wrong parameter %d type for opcode %d, expected: %c", i, instr->id, c);
        }
        ++i;
    }
    if (format[i] != '\0') {
        state->was_error = 1;
        yyerror(state, "not enough parameters for opcode %d", instr->id);
    }
}

static uint32_t
instr_get_size(
    parser_state_t* state,
    thanm_instr_t* instr
) {
    uint32_t size = sizeof(anm_instr_t);
    /* In ANM, parameter size is always 4 bytes (only int32 or float), so we can just add 4 to size for every param... */
    list_node_t* node;
    list_for_each_node(&instr->params, node)
        size += 4;

    return size;
}

static thanm_instr_t*
instr_new(
    parser_state_t* state,
    uint16_t id,
    list_t* params
) {
    thanm_instr_t* instr = thanm_instr_new();
    instr->type = THANM_INSTR_INSTR;
    instr->time = state->time;
    instr->offset = state->offset;
    instr->id = id;
    instr->params = *params;
    free(params);
    instr->size = instr_get_size(state, instr);
    instr_check_types(state, instr);
    state->offset += instr->size;
    return instr;
}

static int
identifier_instr(
    char* ident
) {
    if (strncmp(ident, "ins_", 4) == 0) {
        size_t i = strlen(ident) - 1;
        int valid = 1;
        int num = 0;
        int n = 1;
        while(i >= 4 && valid) {
            char c = ident[i];
            if (c < '0' || c > '9') {
                valid = 0;
            } else {
                num += (c - '0') * n;
            }
            --i;
            n *= 10;
        }
        if (valid)
            return num;
    }
    seqmap_entry_t* ent = seqmap_find(g_anmmap->ins_names, ident);
    if (ent)
        return ent->key;
    return -1;
}

static global_t*
global_find(
    parser_state_t* state,
    const char* name
) {
    global_t* global;
    list_for_each(&state->globals, global) {
        if (strcmp(name, global->name) == 0)
            return global;
    }
    return NULL;
}

static thanm_param_t*
param_copy(
    thanm_param_t* param
) {
    thanm_param_t* copy = (thanm_param_t*)malloc(sizeof(thanm_instr_t));
    copy->type = param->type;
    copy->is_var = param->is_var;
    value_t* val_copy = (value_t*)malloc(sizeof(value_t));
    memcpy(val_copy, param->val, sizeof(value_t));
    if (val_copy->type == 'z')
        val_copy->val.z = strdup(val_copy->val.z);
    copy->val = val_copy;
    return copy;
}

void
yyerror(
    const parser_state_t* state,
    const char* format,
    ...)
{
    if (yylloc.first_line == yylloc.last_line) {
        if (yylloc.first_column == yylloc.last_column) {
            fprintf(stderr,
                    "%s:%s:%d,%d: ",
                    argv0, current_input,
                    yylloc.first_line, yylloc.first_column);
        } else {
            fprintf(stderr,
                    "%s:%s:%d,%d-%d: ",
                    argv0, current_input, yylloc.first_line,
                    yylloc.first_column, yylloc.last_column);
        }
    } else {
        fprintf(stderr,
                "%s:%s:%d,%d-%d,%d: ",
                argv0, current_input, yylloc.first_line,
                yylloc.first_column, yylloc.last_line, yylloc.last_column);
    }

    va_list ap;
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);

    fputc('\n', stderr);
}