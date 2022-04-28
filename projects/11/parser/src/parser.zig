const std = @import("std");
const tokenizer = @import("./tokenizer.zig");
const symbols = @import("./symbol.zig");
const Tokenizer = tokenizer.Tokenizer;
const TokenType = tokenizer.TokenType;
const Token = tokenizer.Token;
const Scope = symbols.Scope;

pub const Parser = struct {
    class: []const u8,
    tokens: Tokenizer,
    currentToken: Token,
    indentation: usize,
    writer: std.fs.File.Writer,
    scope: Scope,
    allocator: std.mem.Allocator,
    label_counter: u32,

    pub fn init(tokens: *Tokenizer, writer: std.fs.File.Writer, allocator: std.mem.Allocator) !Parser {
        var firstToken = tokens.next().?;
        return Parser{
            .class = "",
            .currentToken = firstToken,
            .tokens = tokens.*,
            .indentation = 0,
            .writer = writer,
            .scope = Scope.init(allocator),
            .allocator = allocator,
            .label_counter = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scope.deinit();
    }
    // 'class' className '{' classVarDec* subroutineDec* '}'
    pub fn parseClass(self: *Parser) void {
        self.eat(.keyword, "class");
        self.class = self.currentToken.value;
        self.eatType(.identifier); // className
        self.eat(.symbol, "{");
        while (self.peekTokenList(&.{ "static", "field" })) {
            self.parseClassVarDec();
        }
        while (self.peekTokenList(&.{ "constructor", "function", "method" })) {
            self.parseSubroutineDec();
        }
        self.eat(.symbol, "}");
    }

    // ('static' | 'field' ) type varName (',' varName)* ';'
    fn parseClassVarDec(self: *Parser) void {
        var x: symbols.Kinds = if (self.peekTokenValue("static")) .static else .field;
        self.eatList(&.{ "static", "field" });
        var symbolType = self.currentToken.value;
        self.nextToken(); // type
        var symbolName = self.currentToken.value;
        self.scope.add(x, symbolType, symbolName);
        self.eatType(.identifier); // varName
        while (self.tryEatToken(.symbol, ",")) {
            symbolName = self.currentToken.value;
            self.scope.add(x, symbolType, symbolName);
            self.eatType(.identifier); // varName
        }
        self.eat(.symbol, ";");
    }

    // ('constructor' | 'function' | 'method') ('void' | type) subroutineName '('parameterList ')' subroutineBody
    fn parseSubroutineDec(self: *Parser) void {
        defer self.popScope();

        var isMethod = self.peekTokenValue("method");
        var isConstructor = self.peekTokenValue("constructor");
        self.eatList(&.{ "constructor", "function", "method" });
        self.nextToken(); // type
        var fname = self.currentToken.value;
        self.eatType(.identifier); // subroutineName
        self.eat(.symbol, "(");
        if (isMethod) {
            self.scope.add(.argument, "this", "this");
        }
        self.parseParameterList();
        self.eat(.symbol, ")");

        self.eat(.symbol, "{");
        var i: u32 = 0;
        while (self.peekToken(.keyword, "var")) {
            i += self.parseVarDec();
        }

        self.writer.print("function {s}.{s} {}\n", .{ self.class, fname, i }) catch return;

        if (isMethod) {
            self.writer.print("push argument 0\n", .{}) catch return;
            self.writer.print("pop pointer 0\n", .{}) catch return;
        } else if (isConstructor) {
            self.writer.print("push constant {}\n", .{self.scope.classVarCount()}) catch return;
            self.writer.print("call Memory.alloc 1\n", .{}) catch return;
            self.writer.print("pop pointer 0\n", .{}) catch return;
        }

        self.parseSubroutineBody();
    }

    // ( (type varName) (',' type varName)*)?
    fn parseParameterList(self: *Parser) void {
        if (self.peekToken(.symbol, ")")) {
            return;
        }
        var symbolType = self.currentToken.value;
        self.nextToken(); // type
        var symbolName = self.currentToken.value;
        self.scope.add(.argument, symbolType, symbolName);
        self.eatType(.identifier); // varName
        while (self.tryEatToken(.symbol, ",")) {
            symbolType = self.currentToken.value;
            self.nextToken(); // type
            symbolName = self.currentToken.value;
            self.scope.add(.argument, symbolType, symbolName);
            self.eatType(.identifier); // varName
        }
    }

    // '{' varDec* statements '}'
    fn parseSubroutineBody(self: *Parser) void {
        self.parseStatements();
        self.eat(.symbol, "}");
    }

    // 'var' type varName (',' varName)* ';
    fn parseVarDec(self: *Parser) u32 {
        var count: u32 = 1;
        self.eat(.keyword, "var");
        var symbolType = self.currentToken.value;
        self.nextToken(); // type
        var symbolName = self.currentToken.value;
        self.scope.add(.local, symbolType, symbolName);
        self.eatType(.identifier); // varName
        while (self.tryEatToken(.symbol, ",")) {
            symbolName = self.currentToken.value;
            self.eatType(.identifier); // varName
            self.scope.add(.local, symbolType, symbolName);
            count += 1;
        }
        self.eat(.symbol, ";");
        return count;
    }

    // letStatement | ifStatement | whileStatement | doStatement | returnStatement
    fn parseStatements(self: *Parser) void {
        while (self.peekTokenList(&.{ "let", "if", "while", "do", "return" })) {
            if (self.peekToken(.keyword, "let")) {
                self.parseLet();
            } else if (self.peekToken(.keyword, "if")) {
                self.parseIf();
            } else if (self.peekToken(.keyword, "while")) {
                self.parseWhile();
            } else if (self.peekToken(.keyword, "do")) {
                self.parseDo();
            } else if (self.peekToken(.keyword, "return")) {
                self.parseReturn();
            }
        }
    }

    // 'let' varName ('[' expression ']')? '=' expression ';'
    fn parseLet(self: *Parser) void {
        self.eat(.keyword, "let");
        var symbolName = self.currentToken.value;
        self.eatType(.identifier); // varName
        if (self.tryEatToken(.symbol, "[")) {
            var symbol = self.scope.lookup(symbolName) orelse return;
            self.parseExpression();
            self.writer.print("push {s} {}\n", .{ symbol.kind.toString(), symbol.index }) catch return;
            self.writer.print("add\n", .{}) catch return;
            self.eat(.symbol, "]");
            self.eat(.symbol, "=");
            self.parseExpression();
            self.writer.print("pop temp 0\n", .{}) catch return;
            self.writer.print("pop pointer 1\n", .{}) catch return;
            self.writer.print("push temp 0\n", .{}) catch return;
            self.writer.print("pop that 0\n", .{}) catch return;
        } else {
            self.eat(.symbol, "=");
            self.parseExpression();
            var symbol = self.scope.lookup(symbolName) orelse return;
            self.writer.print("pop {s} {}\n", .{ symbol.kind.toString(), symbol.index }) catch return;
        }
        self.eat(.symbol, ";");
    }

    // 'if' '(' expression ')' '{' statements '}' ( 'else' '{' statements '}' )?
    fn parseIf(self: *Parser) void {
        self.eat(.keyword, "if");
        self.eat(.symbol, "(");
        self.parseExpression();
        self.eat(.symbol, ")");
        // self.writer.print("not\n", .{}) catch return;
        var labelIfTrue = self.getLabel();
        var labelIfFalse = self.getLabel();

        self.writer.print("if-goto L{}\n", .{labelIfTrue}) catch return;
        self.writer.print("goto L{}\n", .{labelIfFalse}) catch return;
        self.writer.print("label L{}\n", .{labelIfTrue}) catch return;
        self.eat(.symbol, "{");
        self.parseStatements();
        self.eat(.symbol, "}");

        if (self.tryEatToken(.keyword, "else")) {
            var labelIfEnd = self.getLabel();
            self.writer.print("goto L{}\n", .{labelIfEnd}) catch return;
            self.writer.print("label L{}\n", .{labelIfFalse}) catch return;
            self.eat(.symbol, "{");
            self.parseStatements();
            self.eat(.symbol, "}");
            self.writer.print("label L{}\n", .{labelIfEnd}) catch return;
        } else {
            self.writer.print("label L{}\n", .{labelIfFalse}) catch return;
        }
    }

    // 'while' '(' expression ')' '{' statements '}'
    fn parseWhile(self: *Parser) void {
        var labelIndex = self.getLabel();
        self.writer.print("label L{}\n", .{labelIndex}) catch return;
        self.eat(.keyword, "while");
        self.eat(.symbol, "(");
        self.parseExpression();
        self.writer.print("not\n", .{}) catch return;
        var labelIndex2 = self.getLabel();
        self.writer.print("if-goto L{}\n", .{labelIndex2}) catch return;
        self.eat(.symbol, ")");
        self.eat(.symbol, "{");
        self.parseStatements();
        self.eat(.symbol, "}");
        self.writer.print("goto L{}\n", .{labelIndex}) catch return;
        self.writer.print("label L{}\n", .{labelIndex2}) catch return;
    }

    // 'do' subroutineCall ';'
    fn parseDo(self: *Parser) void {
        self.eat(.keyword, "do");
        self.parseSubroutineCall();
        self.writer.print("pop temp 0\n", .{}) catch return;
        self.eat(.symbol, ";");
    }

    // subroutineName '(' expressionList ')' | ( className | varName) '.' subroutineName '(' expressionList ')'
    fn parseSubroutineCall(self: *Parser) void {
        var name = self.currentToken.value;
        self.eatType(.identifier); // subroutineName
        if (self.tryEatToken(.symbol, "(")) {
            self.writer.print("push pointer 0\n", .{}) catch return;
            var numberOfExpressions = self.parseExpressionList();
            self.eat(.symbol, ")");
            self.writer.print("call {s}.{s} {}", .{ self.class, name, numberOfExpressions + 1 }) catch return;
        } else if (self.tryEatToken(.symbol, ".")) {
            var subroutineName = self.currentToken.value;
            self.eatType(.identifier); // subroutineName
            self.eat(.symbol, "(");
            var numberOfExpressions: u32 = 0;
            if (self.scope.lookup(name)) |symbol| {
                self.writer.print("push {s} {}\n", .{ symbol.kind.toString(), symbol.index }) catch return;
                numberOfExpressions += 1;
                name = symbol.symbol.type;
            }
            numberOfExpressions += self.parseExpressionList();
            self.eat(.symbol, ")");

            self.writer.print("call {s}.{s} {}", .{ name, subroutineName, numberOfExpressions }) catch return;
        }
        self.writer.print("\n", .{}) catch return;
    }

    // 'return' expression? ';'
    fn parseReturn(self: *Parser) void {
        self.eat(.keyword, "return");
        if (!self.peekToken(.symbol, ";")) {
            self.parseExpression();
        } else {
            self.writer.print("push constant 0\n", .{}) catch return;
        }
        self.eat(.symbol, ";");
        self.writer.print("return\n", .{}) catch return;
    }

    // term (op term)*
    fn parseExpression(self: *Parser) void {
        self.parseTerm();
        while (self.tryEatOp()) |op| {
            self.parseTerm();
            switch (op) {
                '+' => self.writer.print("add\n", .{}) catch return,
                '-' => self.writer.print("sub\n", .{}) catch return,
                '*' => self.writer.print("call Math.multiply 2\n", .{}) catch return,
                '/' => self.writer.print("call Math.divide 2\n", .{}) catch return,
                '&' => self.writer.print("and\n", .{}) catch return,
                '|' => self.writer.print("or\n", .{}) catch return,
                '<' => self.writer.print("lt\n", .{}) catch return,
                '>' => self.writer.print("gt\n", .{}) catch return,
                '=' => self.writer.print("eq\n", .{}) catch return,
                else => unreachable,
            }
        }
    }

    // integerConstant | stringConstant | keywordConstant | varName | varName '[' expression ']' | subroutineCall | '(' expression ')' | unaryOp term
    fn parseTerm(self: *Parser) void {
        if (self.tryEatToken(.symbol, "(")) {
            self.parseExpression();
            self.eat(.symbol, ")");
        } else if (self.tryEatToken(.symbol, "-")) { // unaryOp
            self.parseTerm();
            self.writer.print("neg\n", .{}) catch return;
        } else if (self.tryEatToken(.symbol, "~")) {
            self.parseTerm();
            self.writer.print("not\n", .{}) catch return;
        } else if (self.peekTokenType(.integerConstant)) {
            self.writer.print("push constant {s}\n", .{self.currentToken.value}) catch return;
            self.nextToken();
        } else if (self.peekTokenType(.stringConstant)) {
            self.writer.print("push constant {}\n", .{self.currentToken.value.len}) catch return;
            self.writer.print("call String.new 1\n", .{}) catch return;
            for (self.currentToken.value) |char| {
                self.writer.print("push constant {}\n", .{char}) catch return;
                self.writer.print("call String.appendChar 2\n", .{}) catch return;
            }
            self.nextToken();
        } else if (self.peekKeywordConstant()) {
            if (self.peekTokenValue("true")) {
                self.writer.print("push constant 0\n", .{}) catch return;
                self.writer.print("not\n", .{}) catch return;
            } else if (self.peekTokenValue("false")) {
                self.writer.print("push constant 0\n", .{}) catch return;
            } else if (self.peekTokenValue("null")) {
                self.writer.print("push constant 0\n", .{}) catch return;
            } else if (self.peekTokenValue("this")) {
                self.writer.print("push pointer 0\n", .{}) catch return;
            }
            self.nextToken();
        } else if (self.peekTokenType(.identifier)) {
            var name = self.currentToken.value;
            self.eatType(.identifier);
            if (self.tryEatToken(.symbol, "[")) {
                var x = self.scope.lookup(name) orelse return;
                self.writer.print("push {s} {}\n", .{ x.kind.toString(), x.index }) catch return;
                self.parseExpression();
                self.eat(.symbol, "]");
                self.writer.print("add\n", .{}) catch return;
                self.writer.print("pop pointer 1\n", .{}) catch return;
                self.writer.print("push that 0\n", .{}) catch return;
            } else if (self.tryEatToken(.symbol, ".")) {
                var subName = self.currentToken.value;
                self.eatType(.identifier);
                self.eat(.symbol, "("); // TODO: this used to be an if, is it still ok?
                var numberOfExpressions = self.parseExpressionList();
                self.eat(.symbol, ")");
                if (self.scope.lookup(name)) |symbol| {
                    self.writer.print("push {s} {}\n", .{ symbol.kind.toString(), symbol.index }) catch return;
                    numberOfExpressions += 1;
                    name = symbol.symbol.type;
                }
                self.writer.print("call {s}.{s} {}\n", .{ name, subName, numberOfExpressions }) catch return;
            } else if (self.tryEatToken(.symbol, "(")) {
                var numberOfExpressions = self.parseExpressionList();
                self.eat(.symbol, ")");
                self.writer.print("push pointer 0\n", .{}) catch return;
                self.writer.print("call {s}.{s} {}\n", .{ self.class, name, numberOfExpressions + 1 }) catch return;
            } else {
                var x = self.scope.lookup(name) orelse return;
                self.writer.print("push {s} {}\n", .{ x.kind.toString(), x.index }) catch return;
            }
        } else {
            std.debug.panic("Inavlid expression: unexpected token {}", .{self.currentToken});
        }
    }

    // (expression (',' expression)* )?
    fn parseExpressionList(self: *Parser) u32 {
        if (self.peekToken(.symbol, ")")) {
            return 0;
        }
        self.parseExpression();
        var i: u32 = 1;
        while (self.tryEatToken(.symbol, ",")) {
            self.parseExpression();
            i += 1;
        }
        return i;
    }

    // 'true' | 'false' | 'null' | 'this'
    fn peekKeywordConstant(self: *Parser) bool {
        return self.peekTokenType(.keyword) and self.peekTokenList(&.{ "true", "false", "null", "this" });
    }

    // '+' | '-' | '*' | '/' | '&' | '|' | '<' | '>' | '='
    fn tryEatOp(self: *Parser) ?u8 {
        var isOp = self.peekTokenType(.symbol) and (self.peekTokenList(&.{ "+", "-", "*", "/", "&", "|", "<", ">", "=" }));
        if (isOp) {
            var currentValue = self.currentToken.value;
            self.nextToken();
            return currentValue[0];
        } else {
            return null;
        }
    }

    // If the token exists, return true and eat it, else return false
    fn tryEatToken(self: *Parser, tokenType: TokenType, value: []const u8) bool {
        var isValid = self.peekToken(tokenType, value);
        if (isValid) {
            self.nextToken();
        }
        return isValid;
    }

    // Check information about the current token
    fn peekToken(self: *Parser, tokenType: TokenType, value: []const u8) bool {
        return self.peekTokenType(tokenType) and self.peekTokenValue(value);
    }
    fn peekTokenType(self: *Parser, tokenType: TokenType) bool {
        return self.currentToken.type == tokenType;
    }
    fn peekTokenValue(self: *Parser, value: []const u8) bool {
        return std.mem.eql(u8, self.currentToken.value, value);
    }

    // Check if the current token has a value that is part of the tokenList
    fn peekTokenList(self: *Parser, tokenList: []const []const u8) bool {
        for (tokenList) |token| {
            if (self.peekTokenValue(token)) {
                return true;
            }
        }
        return false;
    }

    // These eat functions are just peek and then nextToken or error
    fn eatList(self: *Parser, tokenList: []const []const u8) void {
        if (!self.peekTokenList(tokenList)) {
            std.debug.panic("Expected token of value {s} but got token {s}\n", .{ tokenList, self.currentToken.value });
        }
        self.nextToken();
    }
    fn eat(self: *Parser, tokenType: TokenType, value: []const u8) void {
        if (!self.peekToken(tokenType, value)) {
            std.debug.panic("Expected token of type {s} with value {s} but got {s} with value {s}\n", .{ tokenType, value, self.currentToken.type, self.currentToken.value });
        }
        self.nextToken();
    }
    fn eatType(self: *Parser, tokenType: TokenType) void {
        if (!self.peekTokenType(tokenType)) {
            std.debug.panic("Expected token of type {s} but got {s}\n", .{ tokenType, self.currentToken.type });
        }
        self.nextToken();
    }

    fn nextToken(self: *Parser) void {
        self.currentToken = self.tokens.next() orelse return;
    }

    // Used to test the tokenizer
    fn printTokens(self: *Parser) void {
        self.writeTag("tokens");
        defer self.writeTagEnd("tokens");
        while (!self.tokens.is_eof()) {
            self.nextToken();
        }
    }

    fn popScope(self: *Parser) void {
        self.scope.clear();
    }

    fn printScopes(self: *Parser) void {
        for (self.scope.symbol_list) |symbol_type, i| {
            for (symbol_type.items) |symbol, j| {
                std.log.info("Scope {} {s} {s} {}\n", .{ @intToEnum(symbols.Kinds, i), symbol.name, symbol.type, j });
            }
        }
    }
    fn getLabel(self: *Parser) u32 {
        self.label_counter += 1;
        return self.label_counter - 1;
    }
};