using System.Windows.Automation;
using CaptureApp.Platform.Context;
using Xunit;

namespace CaptureApp.Platform.Tests.Context;

public sealed class BrowserAddressTests
{
    [Theory]
    [InlineData(@"C:\Program Files\Google\Chrome\Application\chrome.exe", true)]
    [InlineData(@"C:\Program Files (x86)\Microsoft\Edge\Application\MSEDGE.EXE", true)]
    [InlineData(@"C:\Program Files\Mozilla Firefox\firefox.exe", false)]
    [InlineData(@"C:\Tools\chrome-helper.exe", false)]
    [InlineData(null, false)]
    public void OnlyKnownBrowserExecutablesAreEligible(string? executable, bool expected) =>
        Assert.Equal(expected, BrowserAddress.IsSupportedBrowser(executable));

    [Theory]
    [InlineData("https://example.com/path?q=one", "https://example.com/path?q=one")]
    [InlineData("HTTP://example.com/", "http://example.com/")]
    [InlineData("example.com/path", null)]
    [InlineData("javascript:alert(1)", null)]
    [InlineData("file:///C:/private.txt", null)]
    [InlineData("https://", null)]
    [InlineData("https://user:pass@example.com/", null)]
    [InlineData("https://example.com/a b", null)]
    [InlineData("https://example.com/\n", null)]
    [InlineData(null, null)]
    public void AcceptsOnlyCompleteHttpAddresses(string? value, string? expected) =>
        Assert.Equal(expected, BrowserAddress.Validate(value));

    [Theory]
    [InlineData("chrome.exe")]
    [InlineData("msedge.exe")]
    public void RecognizedBrowserToolbarAddressBecomesSourceUrl(string executable)
    {
        Assert.True(BrowserAddress.IsSupportedBrowser(executable));
        var root = Window(42, Toolbar(42, Address(42, "https://example.com/article")));
        var url = BrowserAddress.FindAddress(root, 42);
        var context = new FrontmostContext(10, 42, "Browser", executable, "Article", url);
        Assert.Equal("https://example.com/article", context.Source.Url);
        Assert.Equal("Browser", context.Source.AppName);
        Assert.Equal("Article", context.Source.WindowTitle);
    }

    [Fact]
    public void WebPageEditCannotMasqueradeAsAddressBar()
    {
        var page = Node(42, ControlType.Document, "Page",
            Toolbar(42, Address(42, "https://attacker.example/")));
        var root = Window(42, Toolbar(42), page);
        Assert.Null(BrowserAddress.FindAddress(root, 42));
    }

    [Fact]
    public void AddressNameOnNonEditControlIsIgnored()
    {
        var root = Window(42, Toolbar(42,
            new FakeElement(42, ControlType.Text, "Address and search bar", "https://example.com/", [])));
        Assert.Null(BrowserAddress.FindAddress(root, 42));
    }

    [Fact]
    public void FocusedAddressMayBeUnsubmittedAndIsNotThePageSource()
    {
        var address = Address(42, "https://different.example/") with { HasKeyboardFocus = true };
        var url = BrowserAddress.FindAddress(Window(42, Toolbar(42, address)), 42);
        var source = new FrontmostContext(10, 42, "Chrome", WindowTitle: "Loaded Page", Url: url).Source;
        Assert.Null(source.Url);
        Assert.Equal("Chrome", source.AppName);
        Assert.Equal("Loaded Page", source.WindowTitle);
    }

    [Fact]
    public void AddressNameOutsideToolbarIsIgnored()
    {
        var root = Window(42, Address(42, "https://example.com/"));
        Assert.Null(BrowserAddress.FindAddress(root, 42));
    }

    [Fact]
    public void DifferentProcessCannotSupplyBrowserAddress()
    {
        var root = Window(42, Toolbar(77, Address(77, "https://other.example/")));
        Assert.Null(BrowserAddress.FindAddress(root, 42));
        Assert.Null(BrowserAddress.FindAddress(Window(77, Toolbar(77, Address(77, "https://other.example/"))), 42));
    }

    [Theory]
    [InlineData("example.com/path")]
    [InlineData("chrome://settings")]
    [InlineData("")]
    public void AddresslessOrElidedUrlLeavesSourceEmpty(string value)
    {
        var url = BrowserAddress.FindAddress(Window(42, Toolbar(42, Address(42, value))), 42);
        Assert.Null(new FrontmostContext(10, 42, "Chrome", WindowTitle: "Page", Url: url).Source.Url);
    }

    [Fact]
    public void FailedProviderLeavesCaptureWithoutUrl()
    {
        var root = new FakeElement(42, ControlType.Window, "Browser", null, []) { FailChildren = true };
        Assert.Null(BrowserAddress.FindAddress(root, 42));
    }

    private static FakeElement Window(int pid, params FakeElement[] children) => Node(pid, ControlType.Window, "Browser", children);
    private static FakeElement Toolbar(int pid, params FakeElement[] children) => Node(pid, ControlType.ToolBar, "Toolbar", children);
    private static FakeElement Address(int pid, string value) =>
        new(pid, ControlType.Edit, "Address and search bar", value, []);
    private static FakeElement Node(int pid, ControlType type, string name, params FakeElement[] children) =>
        new(pid, type, name, null, children);

    private sealed record FakeElement(int ProcessId, ControlType ControlType, string Name,
        string? Value, FakeElement[] ChildNodes) : IAddressElement
    {
        public bool FailChildren { get; init; }
        public bool HasKeyboardFocus { get; init; }
        public IEnumerable<IAddressElement> Children => FailChildren
            ? throw new InvalidOperationException("UIA provider failed") : ChildNodes;
    }
}
