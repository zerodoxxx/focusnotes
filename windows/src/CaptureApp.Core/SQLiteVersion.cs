namespace CaptureApp.Core;

public static class SQLiteVersion
{
    public static string String
    {
        get
        {
            Index.SQLiteProvider.Initialize();
            return SQLitePCL.raw.sqlite3_libversion().utf8_to_string();
        }
    }

    public static int Number
    {
        get
        {
            Index.SQLiteProvider.Initialize();
            return SQLitePCL.raw.sqlite3_libversion_number();
        }
    }
}
