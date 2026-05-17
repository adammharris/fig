pub fn validate(comptime Language: type) void {
  comptime {
    if (!@hasDecl(Language, "Type"))
      @compileError("Language must define Type");

    if (!@hasDecl(Language, "default_type"))
      @compileError("Language must define default_type");

    if (!@hasDecl(Language, "parse"))
      @compileError("Language must define parse");
  }
}
