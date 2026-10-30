namespace VaultBridge.Windows;

public sealed class CredentialRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Source { get; set; } = "VaultBridge";
    public string SourceAccount { get; set; } = "";
    public string Origin { get; set; } = "";
    public string Title { get; set; } = "";
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
    public string Note { get; set; } = "";
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public string Identity => string.Join('\u001f', Source, SourceAccount,
        Origin.ToLowerInvariant(), Username);
    public string SourceLabel => string.IsNullOrWhiteSpace(SourceAccount)
        ? Source : $"{Source} · {SourceAccount}";
}
