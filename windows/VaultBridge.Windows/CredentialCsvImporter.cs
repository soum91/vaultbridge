using Microsoft.VisualBasic.FileIO;

namespace VaultBridge.Windows;

public static class CredentialCsvImporter
{
    public static IReadOnlyList<CredentialRecord> Import(string filePath, string source, string account)
    {
        using var parser = new TextFieldParser(filePath);
        parser.TextFieldType = FieldType.Delimited;
        parser.SetDelimiters(",");
        parser.HasFieldsEnclosedInQuotes = true;
        parser.TrimWhiteSpace = false;
        var headers = parser.ReadFields()?.Select(h => h.Trim().TrimStart('\ufeff').ToLowerInvariant()).ToArray()
            ?? throw new InvalidDataException("CSV is empty.");

        int Find(params string[] names) => Array.FindIndex(headers, h => names.Contains(h));
        int site = Find("url", "website", "origin", "login_uri", "hostname", "site");
        int user = Find("username", "user name", "login", "user");
        int password = Find("password", "pass");
        int title = Find("name", "title");
        int note = Find("note", "notes");
        if (site < 0 || user < 0 || password < 0)
            throw new InvalidDataException("CSV needs site/URL, username and password columns.");

        static string Value(string[] row, int index, bool trim = true) => index >= 0 && index < row.Length
            ? (trim ? row[index].Trim() : row[index]) : "";
        var output = new List<CredentialRecord>();
        while (!parser.EndOfData)
        {
            var fields = parser.ReadFields();
            if (fields is null) continue;
            string origin = Value(fields, site);
            // Preserve leading/trailing spaces in passwords exactly.
            string secret = Value(fields, password, trim: false);
            if (origin.Length == 0 || secret.Length == 0) continue;
            string label = Value(fields, title);
            if (label.Length == 0) label = Uri.TryCreate(origin, UriKind.Absolute, out var uri)
                ? uri.Host : origin;
            output.Add(new CredentialRecord
            {
                Source = source, SourceAccount = account, Origin = origin, Title = label,
                Username = Value(fields, user), Password = secret,
                Note = Value(fields, note)
            });
        }
        return output;
    }
}
