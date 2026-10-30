using System.Security.Cryptography;
using System.Text.Json;
using System.IO;

namespace VaultBridge.Windows;

public sealed class ProtectedVault
{
    private readonly string path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "VaultBridge", "vault.dat");

    public IReadOnlyList<CredentialRecord> Load()
    {
        if (!File.Exists(path)) return Array.Empty<CredentialRecord>();
        byte[] encrypted = File.ReadAllBytes(path);
        byte[] plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<List<CredentialRecord>>(plaintext)
                ?? throw new InvalidDataException("Credential vault format is invalid.");
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    public void Save(IEnumerable<CredentialRecord> credentials)
    {
        byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(credentials);
        byte[] encrypted;
        try { encrypted = ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(plaintext); }

        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string pending = path + ".pending";
        File.WriteAllBytes(pending, encrypted);
        File.Move(pending, path, overwrite: true);
    }
}
