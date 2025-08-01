#+feature dynamic-literals
package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"

import "src:common"

write_hover_content :: proc(ast_context: ^AstContext, symbol: Symbol) -> MarkupContent {
	content: MarkupContent

	symbol := symbol

	if untyped, ok := symbol.value.(SymbolUntypedValue); ok {
		switch untyped.type {
		case .String:
			symbol.signature = "string"
		case .Bool:
			symbol.signature = "bool"
		case .Float:
			symbol.signature = "float"
		case .Integer:
			symbol.signature = "int"
		}
	}

	cat := concatenate_symbol_information(ast_context, symbol)

	if cat != "" {
		content.kind = "markdown"
		content.value = fmt.tprintf("```odin\n%v\n```%v", cat, symbol.doc)
	} else {
		content.kind = "plaintext"
	}

	return content
}

builtin_identifier_hover: map[string]string = {
	"context" = fmt.aprintf(
		"```odin\n%v\n```\n%v",
		"runtime.context: Context",
		"This context variable is local to each scope and is implicitly passed by pointer to any procedure call in that scope (if the procedure has the Odin calling convention).",
	),
}


get_hover_information :: proc(document: ^Document, position: common.Position) -> (Hover, bool, bool) {
	hover := Hover {
		contents = {kind = "plaintext"},
	}

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
	)

	position_context, ok := get_document_position_context(document, position, .Hover)
	if !ok {
		log.warn("Failed to get position context")
		return hover, false, false
	}

	ast_context.position_hint = position_context.hint

	get_globals(document.ast, &ast_context)

	if position_context.function != nil {
		get_locals(document.ast, position_context.function, &ast_context, &position_context)
	}

	if position_context.import_stmt != nil {
		return {}, false, true
	}

	if position_context.identifier != nil {
		if ident, ok := position_context.identifier.derived.(^ast.Ident); ok {
			if _, ok := keyword_map[ident.name]; ok {
				hover.contents.kind = "plaintext"
				hover.range = common.get_token_range(position_context.identifier^, ast_context.file.src)
				return hover, true, true
			}

			if str, ok := builtin_identifier_hover[ident.name]; ok {
				hover.contents.kind = "markdown"
				hover.contents.value = str
				hover.range = common.get_token_range(position_context.identifier^, ast_context.file.src)
				return hover, true, true
			}
		}
	}

	if position_context.implicit_context != nil {
		if str, ok := builtin_identifier_hover[position_context.implicit_context.tok.text]; ok {
			hover.contents.kind = "markdown"
			hover.contents.value = str
			hover.range = common.get_token_range(position_context.implicit_context^, ast_context.file.src)
			return hover, true, true
		}
	}

	if position_context.value_decl != nil && len(position_context.value_decl.names) != 0 {
		if position_context.enum_type != nil {
			if enum_symbol, ok := resolve_type_expression(&ast_context, position_context.value_decl.names[0]); ok {
				if v, ok := enum_symbol.value.(SymbolEnumValue); ok {
					for field in position_context.enum_type.fields {
						if ident, ok := field.derived.(^ast.Ident); ok {
							if position_in_node(ident, position_context.position) {
								for name, i in v.names {
									if name == ident.name {
										construct_enum_field_symbol(&enum_symbol, v, i)
										hover.contents = write_hover_content(&ast_context, enum_symbol)
										return hover, true, true
									}
								}
							}
						} else if value, ok := field.derived.(^ast.Field_Value); ok {
							if position_in_node(value.field, position_context.position) {
								if ident, ok := value.field.derived.(^ast.Ident); ok {
									for name, i in v.names {
										if name == ident.name {
											construct_enum_field_symbol(&enum_symbol, v, i)
											hover.contents = write_hover_content(&ast_context, enum_symbol)
										}
									}
								}
								return hover, true, true
							}
						}
					}
				}
			}
		}

		if position_context.struct_type != nil {
			for field, field_index in position_context.struct_type.fields.list {
				for name, name_index in field.names {
					if position_in_node(name, position_context.position) {
						if identifier, ok := name.derived.(^ast.Ident); ok && field.type != nil {
							if symbol, ok := resolve_type_expression(&ast_context, field.type); ok {
								if struct_symbol, ok := resolve_type_expression(
									&ast_context,
									position_context.value_decl.names[0],
								); ok {
									if value, ok := struct_symbol.value.(SymbolStructValue); ok {
										construct_struct_field_symbol(&symbol, struct_symbol.name, value, field_index+name_index)
										build_documentation(&ast_context, &symbol, true)
										hover.contents = write_hover_content(&ast_context, symbol)
										return hover, true, true
									}
								}
							}
						}
					}
				}
			}
		}

		if position_context.bit_field_type != nil {
			for field, i in position_context.bit_field_type.fields {
				if position_in_node(field.name, position_context.position) {
					if identifier, ok := field.name.derived.(^ast.Ident); ok && field.type != nil {
						if symbol, ok := resolve_type_expression(&ast_context, field.type); ok {
							if bit_field_symbol, ok := resolve_type_expression(
								&ast_context,
								position_context.value_decl.names[0],
							); ok {
								if value, ok := bit_field_symbol.value.(SymbolBitFieldValue); ok {
									construct_bit_field_field_symbol(&symbol, bit_field_symbol.name, value, i)
									hover.contents = write_hover_content(&ast_context, symbol)
									return hover, true, true
								}
							}
						}
					}
				}
			}
		}
	}

	if position_context.field_value != nil && position_in_node(position_context.field_value.field, position_context.position) {
		if position_context.comp_lit != nil {
			if comp_symbol, ok := resolve_comp_literal(&ast_context, &position_context); ok {
				if field, ok := position_context.field_value.field.derived.(^ast.Ident); ok {
					if position_in_node(field, position_context.position) {
						if v, ok := comp_symbol.value.(SymbolStructValue); ok {
							for name, i in v.names {
								if name == field.name {
									if symbol, ok := resolve_type_expression(&ast_context, v.types[i]); ok {
										construct_struct_field_symbol(&symbol, comp_symbol.name, v, i)
										build_documentation(&ast_context, &symbol, true)
										hover.contents = write_hover_content(&ast_context, symbol)
										return hover, true, true
									}
								}
							}
						}
					} else if v, ok := comp_symbol.value.(SymbolBitFieldValue); ok {
						for name, i in v.names {
							if name == field.name {
								if symbol, ok := resolve_type_expression(&ast_context, v.types[i]); ok {
									construct_bit_field_field_symbol(&symbol, comp_symbol.name, v, i)
									hover.contents = write_hover_content(&ast_context, symbol)
									return hover, true, true
								}
							}
						}
					}
				}
			}
		}

		if position_context.call != nil {
			if symbol, ok := resolve_type_location_proc_param_name(&ast_context, &position_context); ok {
				build_documentation(&ast_context, &symbol, false)
				hover.contents = write_hover_content(&ast_context, symbol)
				return hover, true, true
			}
		}
	}

	if position_context.selector != nil &&
	   position_context.identifier != nil &&
	   position_context.field == position_context.identifier {
		hover.range = common.get_token_range(position_context.identifier^, ast_context.file.src)

		reset_ast_context(&ast_context)

		ast_context.current_package = ast_context.document_package

		//if the base selector is the client wants to go to.
		if base, ok := position_context.selector.derived.(^ast.Ident); ok && position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)^

			if position_in_node(base, position_context.position) {
				if resolved, ok := resolve_type_identifier(&ast_context, ident); ok {
					build_documentation(&ast_context, &resolved, false)
					resolved.name = ident.name

					if resolved.type == .Variable {
						resolved.pkg = ast_context.document_package
					}

					hover.contents = write_hover_content(&ast_context, resolved)
					return hover, true, true
				}
			}
		}

		selector: Symbol

		selector, ok = resolve_type_expression(&ast_context, position_context.selector)

		if !ok {
			return hover, false, true
		}

		field: string

		if position_context.field != nil {
			#partial switch v in position_context.field.derived {
			case ^ast.Ident:
				field = v.name
			}
		}

		if v, is_proc := selector.value.(SymbolProcedureValue); is_proc {
			if len(v.return_types) == 0 || v.return_types[0].type == nil {
				return {}, false, false
			}

			set_ast_package_set_scoped(&ast_context, selector.pkg)

			if selector, ok = resolve_type_expression(&ast_context, v.return_types[0].type); !ok {
				return {}, false, true
			}
		}

		ast_context.current_package = selector.pkg

		#partial switch v in selector.value {
		case SymbolStructValue:
			for name, i in v.names {
				if name == field {
					if symbol, ok := resolve_type_expression(&ast_context, v.types[i]); ok {
						construct_struct_field_symbol(&symbol, selector.name, v, i)
						build_documentation(&ast_context, &symbol, true)
						hover.contents = write_hover_content(&ast_context, symbol)
						return hover, true, true
					}
				}
			}
		case SymbolBitFieldValue:
			for name, i in v.names {
				if name == field {
					if symbol, ok := resolve_type_expression(&ast_context, v.types[i]); ok {
						construct_bit_field_field_symbol(&symbol, selector.name, v, i)
						hover.contents = write_hover_content(&ast_context, symbol)
						return hover, true, true
					}
				}
			}
		case SymbolPackageValue:
			if position_context.field != nil {
				if ident, ok := position_context.field.derived.(^ast.Ident); ok {
					// check to see if we are in a position call context
					if position_context.call != nil && ast_context.call == nil {
						if call, ok := position_context.call.derived.(^ast.Call_Expr); ok {
							if !position_in_exprs(call.args, position_context.position) {
								ast_context.call = call
							}
						}
					}
					if resolved, ok := resolve_type_identifier(&ast_context, ident^); ok {
						build_documentation(&ast_context, &resolved, false)
						resolved.name = ident.name

						if resolved.type == .Variable {
							resolved.pkg = ast_context.document_package
						}


						hover.contents = write_hover_content(&ast_context, resolved)
						return hover, true, true
					}
				}
			}
		case SymbolEnumValue:
			for name, i in v.names {
				if name == field {
					symbol := Symbol {
						name      = selector.name,
						pkg       = selector.pkg,
						signature = get_enum_field_signature(v, i),
					}
					hover.contents = write_hover_content(&ast_context, symbol)
					return hover, true, true
				}
			}
		}
	} else if position_context.implicit_selector_expr != nil {
		implicit_selector := position_context.implicit_selector_expr
		if symbol, ok := resolve_implicit_selector(&ast_context, &position_context, implicit_selector); ok {
			#partial switch v in symbol.value {
			case SymbolEnumValue:
				for name, i in v.names {
					if strings.compare(name, implicit_selector.field.name) == 0 {
						construct_enum_field_symbol(&symbol, v, i)
						hover.contents = write_hover_content(&ast_context, symbol)
						return hover, true, true
					}
				}
			case SymbolUnionValue:
				for type in v.types {
					enum_symbol := resolve_type_expression(&ast_context, type) or_continue
					v := enum_symbol.value.(SymbolEnumValue) or_continue
					for name, i in v.names {
						if strings.compare(name, implicit_selector.field.name) == 0 {
							construct_enum_field_symbol(&enum_symbol, v, i)
							hover.contents = write_hover_content(&ast_context, enum_symbol)
							return hover, true, true
						}
					}
				}
			case SymbolBitSetValue:
				if enum_symbol, ok := resolve_type_expression(&ast_context, v.expr); ok {
					if v, ok := enum_symbol.value.(SymbolEnumValue); ok {
						for name, i in v.names {
							if strings.compare(name, implicit_selector.field.name) == 0 {
								construct_enum_field_symbol(&enum_symbol, v, i)
								hover.contents = write_hover_content(&ast_context, enum_symbol)
								return hover, true, true
							}
						}
					}
				}
			}
		}
		return {}, false, true
	} else if position_context.identifier != nil {
		reset_ast_context(&ast_context)

		ast_context.current_package = ast_context.document_package

		ident := position_context.identifier.derived.(^ast.Ident)^

		if position_context.value_decl != nil {
			ident.pos = position_context.value_decl.end
			ident.end = position_context.value_decl.end
		}

		hover.range = common.get_token_range(position_context.identifier^, document.ast.src)

		if position_context.call != nil {
			if call, ok := position_context.call.derived.(^ast.Call_Expr); ok {
				if !position_in_exprs(call.args, position_context.position) {
					ast_context.call = call
				}
			}
		}

		if resolved, ok := resolve_type_identifier(&ast_context, ident); ok {
			resolved.type_name = resolved.name
			resolved.type_pkg = resolved.pkg
			resolved.name = ident.name
			if resolved.type == .Variable {
				resolved.pkg = ast_context.document_package
			}

			build_documentation(&ast_context, &resolved, false)
			hover.contents = write_hover_content(&ast_context, resolved)
			return hover, true, true
		}
	}

	return hover, false, true
}
