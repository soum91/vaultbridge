using Microsoft.Win32;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;

namespace VaultBridge.Windows;

public partial class MainWindow : Window
{
    private readonly ProtectedVault vault = new();
    private readonly ObservableCollection<CredentialRecord> entries = new();
    private readonly DispatcherTimer clipboardTimer = new() { Interval = TimeSpan.FromSeconds(45) };
    private string? lastCopied;

    public MainWindow()
    {
        InitializeComponent();
        CredentialList.ItemsSource = entries;
        ICollectionView view = CollectionViewSource.GetDefaultView(entries);
        view.Filter = Filter;
        try { foreach (var item in vault.Load()) entries.Add(item); }
        catch (Exception ex) { MessageBox.Show("Couldn't open the encrypted vault: " + ex.Message,
            "VaultBridge", MessageBoxButton.OK, MessageBoxImage.Error); }
        clipboardTimer.Tick += (_, _) =>
        {
            clipboardTimer.Stop();
            try { if (lastCopied is not null && Clipboard.ContainsText() && Clipboard.GetText() == lastCopied) Clipboard.Clear(); }
            catch { /* clipboard currently owned by another process */ }
            lastCopied = null;
        };
    }

    private bool Filter(object item)
    {
        if (item is not CredentialRecord row) return false;
        string term = SearchBox?.Text ?? "";
        return term.Length == 0 || new[] { row.Title, row.Origin, row.Username, row.Source, row.SourceAccount }
            .Any(text => text.Contains(term, StringComparison.OrdinalIgnoreCase));
    }

    private void Search_Changed(object sender, TextChangedEventArgs e)
    {
        if (CredentialList?.ItemsSource is not null) CollectionViewSource.GetDefaultView(entries).Refresh();
    }

    private void MergeAndSave(IEnumerable<CredentialRecord> incoming)
    {
        var next = entries.ToList();
        int count = 0;
        foreach (var row in incoming)
        {
            var old = next.FindIndex(c => c.Identity == row.Identity);
            if (old >= 0) { row.Id = next[old].Id; next[old] = row; }
            else next.Add(row);
            count++;
        }
        // Persist before changing the visible list. Never pretend a failed save succeeded.
        vault.Save(next);
        entries.Clear();
        foreach (var row in next) entries.Add(row);
        StatusLabel.Text = $"Saved {count} credential(s) locally. Source files may contain plaintext passwords.";
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFileDialog { Title = "Import password CSV", Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*", CheckFileExists = true };
        if (picker.ShowDialog(this) != true) return;
        string source = SourceBox.SelectedIndex switch
        {
            1 => "Apple Passwords", 2 => "Firefox", _ => "Google Password Manager"
        };
        try
        {
            var imported = CredentialCsvImporter.Import(picker.FileName, source, AccountBox.Text.Trim());
            MergeAndSave(imported);
            MessageBox.Show($"Imported {imported.Count} entries. Verify them and delete the original plaintext CSV from Downloads/cloud storage.",
                "Import complete", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Import failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void Add_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new AddCredentialDialog { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Credential is null) return;
        try { MergeAndSave(new[] { dialog.Credential }); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Save failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (CredentialList.SelectedItem is not CredentialRecord item) return;
        if (MessageBox.Show("Copy this secret to the Windows clipboard? Other clipboard apps (including Drift sync) may read it.",
            "Clipboard exposure", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        try
        {
            Clipboard.SetText(item.Password);
            lastCopied = item.Password;
            clipboardTimer.Stop();
            clipboardTimer.Start();
            StatusLabel.Text = "Password copied. VaultBridge will clear it in 45 seconds only if unchanged.";
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Copy failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (CredentialList.SelectedItem is not CredentialRecord item) return;
        if (MessageBox.Show($"Remove local entry for {item.Title}? This will not delete it from the original manager.",
            "Delete entry", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try
        {
            var remaining = entries.Where(e => e.Id != item.Id).ToList();
            vault.Save(remaining);
            entries.Remove(item);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Delete failed", MessageBoxButton.OK, MessageBoxImage.Error); }
    }
}
