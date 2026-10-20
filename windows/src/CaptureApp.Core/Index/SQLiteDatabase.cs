using Microsoft.Data.Sqlite;
using System.Text;

namespace CaptureApp.Core.Index;

internal readonly record struct SQLiteValue(object? Value)
{
    internal static SQLiteValue Text(string? value) => new(value);
    internal static SQLiteValue Int(long value) => new(value);
    internal static SQLiteValue Double(double value) => new(value);
    internal static SQLiteValue Null => new(null);
}

internal sealed class SQLiteDatabase : IDisposable
{
    private readonly SqliteConnection connection;
    // Reused across calls so each SQL text is prepared once (as Swift's long-lived statements).
    private readonly Dictionary<string, SQLiteStatement> cached = new(StringComparer.Ordinal);

    internal SQLiteDatabase(string path, bool memory = false)
    {
        SQLiteProvider.Initialize();
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = memory ? SqliteOpenMode.Memory : SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
            DefaultTimeout = 2
        };
        connection = new SqliteConnection(builder.ToString());
        connection.Open();
        try
        {
            Exec("PRAGMA busy_timeout = 2000; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;");
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    internal static void ProbeFTS5()
    {
        using var database = new SQLiteDatabase(":memory:", memory: true);
        database.Exec("CREATE VIRTUAL TABLE temp.__fts5_probe USING fts5(content); DROP TABLE temp.__fts5_probe;");
    }

    internal SQLiteStatement Prepare(string sql) => new(connection, sql);

    internal void Exec(string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    internal void Execute(string sql, params SQLiteValue[] values)
    {
        if (!cached.TryGetValue(sql, out var statement))
        {
            cached[sql] = statement = Prepare(sql);
        }

        statement.Run(values);
    }

    internal long LastInsertedId
    {
        get
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT last_insert_rowid()";
            return Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
        }
    }

    internal T Transaction<T>(Func<T> body)
    {
        Execute("BEGIN IMMEDIATE");
        try
        {
            var result = body();
            Execute("COMMIT");
            return result;
        }
        catch
        {
            try { Execute("ROLLBACK"); }
            catch (SqliteException) { }
            throw;
        }
    }

    internal void Transaction(Action body) => Transaction(() =>
    {
        body();
        return true;
    });

    public void Dispose()
    {
        foreach (var statement in cached.Values)
        {
            statement.Dispose();
        }

        cached.Clear();
        connection.Dispose();
    }
}

internal sealed class SQLiteStatement : IDisposable
{
    private readonly SqliteCommand command;
    private SqliteDataReader? reader;

    internal SQLiteStatement(SqliteConnection connection, string sql)
    {
        command = connection.CreateCommand();
        command.CommandText = NameParameters(sql);
    }

    internal void Bind(IReadOnlyList<SQLiteValue> values)
    {
        reader?.Dispose();
        reader = null;
        command.Parameters.Clear();
        for (var i = 0; i < values.Count; i++)
        {
            command.Parameters.AddWithValue("$p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture), values[i].Value ?? DBNull.Value);
        }
    }

    internal bool Step()
    {
        reader ??= command.ExecuteReader();
        if (reader.Read())
        {
            return true;
        }

        reader.Dispose();
        reader = null;
        return false;
    }

    internal void Run(params SQLiteValue[] values)
    {
        Bind(values);
        command.ExecuteNonQuery();
    }

    internal bool IsNull(int column) => Current().IsDBNull(column);
    internal long Int(int column) => Current().GetInt64(column);
    internal double Double(int column) => Current().GetDouble(column);
    internal string? Text(int column) => IsNull(column) ? null : Current().GetString(column);

    private SqliteDataReader Current() => reader ?? throw new InvalidOperationException("The statement is not positioned on a row.");

    public void Dispose()
    {
        reader?.Dispose();
        command.Dispose();
    }

    private static string NameParameters(string sql)
    {
        var output = new StringBuilder(sql.Length + 16);
        var quote = '\0';
        var index = 0;
        for (var i = 0; i < sql.Length; i++)
        {
            var character = sql[i];
            if (quote != '\0')
            {
                output.Append(character);
                if (character == quote)
                {
                    if (i + 1 < sql.Length && sql[i + 1] == quote)
                    {
                        output.Append(sql[++i]);
                    }
                    else
                    {
                        quote = '\0';
                    }
                }

                continue;
            }

            if (character is '\'' or '"')
            {
                quote = character;
                output.Append(character);
            }
            else if (character == '?')
            {
                output.Append("$p").Append(index++.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            else
            {
                output.Append(character);
            }
        }

        return output.ToString();
    }
}

internal static class SQLiteProvider
{
    private static readonly object Gate = new();
    private static bool initialized;

    internal static void Initialize()
    {
        lock (Gate)
        {
            if (initialized)
            {
                return;
            }

            SQLitePCL.Batteries_V2.Init();
            initialized = true;
        }
    }
}
