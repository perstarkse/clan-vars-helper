# Fixture: tags at BOTH levels. extractTags must union them, so
# includeTags matching only the inner tag still discovers gen-both.
{
  meta = { tags = [ "tag-outer" ]; };
  "gen-both" = {
    meta = { tags = [ "tag-both-inner" ]; };
    files.dummy = { };
  };
}
