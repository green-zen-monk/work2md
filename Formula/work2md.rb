class Work2md < Formula
  desc "Atlassian Jira and Confluence export CLIs"
  homepage "https://github.com/green-zen-monk/work2md"
  url "https://github.com/green-zen-monk/work2md/releases/download/v0.9.0/work2md_0.9.0_portable.tar.gz"
  version "0.9.0"
  sha256 "552e1da2089dc16a13f17bf07bbeafbaeff2c83136d627eed90a74f25add1fd2"

  depends_on "python"

  def install
    bin.install "jira2md", "confluence2md", "work2md-config"
    pkgshare.install "lib", "scripts", "VERSION", "README.md", "CHANGELOG.md"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/jira2md --version")
    assert_match version.to_s, shell_output("#{bin}/confluence2md --version")
    assert_match version.to_s, shell_output("#{bin}/work2md-config --version")
  end
end
