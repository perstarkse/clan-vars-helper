# Fixture: tags only at the top level.
{
  meta = { tags = [ "tag-top" ]; };
  "gen-top" = {
    files.dummy = { };
  };
}
