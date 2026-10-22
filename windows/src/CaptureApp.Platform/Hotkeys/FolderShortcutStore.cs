using System.Text.Json;
using CaptureApp.Core;

namespace CaptureApp.Platform.Hotkeys;

public enum FolderShortcutAction { QuickNote, StartSession }

public sealed record FolderShortcutBinding(Guid Id, KeyChord Shortcut, FolderShortcutAction Action, string Folder);

/// <summary>Folder bindings belong to one vault's state, separate from global built-in shortcuts.</summary>
public sealed class FolderShortcutStore(string path)
{
    public const int MaximumBindings = 20;
    private readonly string fullPath = Path.GetFullPath(path);
    private sealed record SavedBinding(Guid Id, string Shortcut, FolderShortcutAction Action, string Folder);
    private sealed record Envelope(int Version, SavedBinding[] Bindings);

    public IReadOnlyList<FolderShortcutBinding> Load()
    {
        byte[] bytes;
        try { bytes = File.ReadAllBytes(fullPath); }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }
        try
        {
            var envelope = JsonSerializer.Deserialize<Envelope>(bytes);
            if (envelope is null || envelope.Version != 1 || envelope.Bindings is null)
                throw new InvalidDataException("Unsupported or invalid folder shortcut settings. The file was left unchanged.");
            var bindings = envelope.Bindings.Select(binding => binding is null
                ? throw new InvalidDataException("Invalid folder shortcut entry.")
                : new FolderShortcutBinding(binding.Id, KeyChord.Parse(binding.Shortcut), binding.Action, binding.Folder)).ToArray();
            Validate(bindings);
            return bindings;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or FormatException)
        {
            throw new InvalidDataException("Folder shortcut settings are invalid. The file was left unchanged.", error);
        }
    }

    public void Save(IReadOnlyList<FolderShortcutBinding> bindings)
    {
        Validate(bindings);
        var envelope = new Envelope(1, bindings.Select(binding => new SavedBinding(binding.Id,
            binding.Shortcut.DisplayString, binding.Action, binding.Folder)).ToArray());
        var bytes = JsonSerializer.SerializeToUtf8Bytes(envelope, new JsonSerializerOptions { WriteIndented = true });
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        var temporary = fullPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, fullPath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) { File.Delete(temporary); } }
    }

    public static void Validate(IReadOnlyList<FolderShortcutBinding> bindings,
        IReadOnlyDictionary<HotkeyAction, KeyChord>? builtIns = null, IReadOnlySet<string>? disabledBuiltIns = null)
    {
        ArgumentNullException.ThrowIfNull(bindings);
        if (bindings.Count > MaximumBindings) { throw new InvalidDataException($"You can add up to {MaximumBindings} folder shortcuts."); }
        var ids = new HashSet<Guid>();
        var chords = new HashSet<KeyChord>();
        foreach (var binding in bindings)
        {
            if (binding is null || binding.Id == Guid.Empty || !ids.Add(binding.Id))
                throw new InvalidDataException("Each folder shortcut must have a unique nonempty identity.");
            if (!Enum.IsDefined(binding.Action)) { throw new InvalidDataException("Choose a valid folder shortcut action."); }
            var chord = binding.Shortcut;
            var validation = HotkeyValidator.Validate(chord);
            if (!validation.IsValid) { throw new InvalidDataException(validation.Error); }
            if ((chord.Modifiers & (HotkeyModifiers.Control | HotkeyModifiers.Alt)) == 0
                || chord.VirtualKey is < 1 or > 255 or 0x1B or 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5)
                throw new InvalidDataException("Choose a key with Ctrl or Alt. Escape and modifier keys cannot be used.");
            if (!chords.Add(chord)) { throw new InvalidDataException("This combination is already used by another folder shortcut."); }
            if (builtIns is not null && builtIns.Any(pair => pair.Value == chord && disabledBuiltIns?.Contains(pair.Key.ToString()) != true))
                throw new InvalidDataException("This combination is already used by a built-in shortcut.");
            ValidateFolder(binding);
        }
    }

    private static void ValidateFolder(FolderShortcutBinding binding)
    {
        try
        {
            var folder = new NoteFolder(binding.Folder);
            if (binding.Action == FolderShortcutAction.QuickNote && folder.Components[0].Equals("assets", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException();
        }
        catch (ArgumentException error)
        {
            throw new InvalidDataException("Choose a nonempty relative folder without traversal, hidden names, reserved assets, or invalid Windows names.", error);
        }
    }
}
