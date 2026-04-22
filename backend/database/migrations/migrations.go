package migrations

// Migration holds a schema version and the SQL statements to apply.
type Migration struct {
	Version int
	Stmts   []string
}

// All is the ordered list of all schema migrations.
var All = []Migration{
	{1, V1},
	{2, V2},
	{3, V3},
	{4, V4},
}
