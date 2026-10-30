using System.Windows;

namespace VaultBridge.Windows;

public partial class AddCredentialDialog : Window
{
    public CredentialRecord? Credential { get; private set; }

    public AddCredentialDialog() => InitializeComponent();

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(UrlBox.Text) || string.IsNullOrWhiteSpace(SecretBox.Password))
        {
            MessageBox.Show("Website URL and password are required.", "VaultBridge");
            return;
        }
        Credential = new CredentialRecord
        {
            Source = "VaultBridge", Origin = UrlBox.Text.Trim(),
            Title = string.IsNullOrWhiteSpace(TitleBox.Text) ? UrlBox.Text.Trim() : TitleBox.Text.Trim(),
            Username = UsernameBox.Text.Trim(), Password = SecretBox.Password,
            Note = NotesBox.Text
        };
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
