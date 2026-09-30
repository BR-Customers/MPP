// The binary has to identify itself. With no Authenticode signature (spec open
// item 12.4), the assembly metadata plus a recorded hash is all a plant PC's
// Properties dialog and MPP IT's allowlist have to go on.

using System.Diagnostics;
using System.Reflection;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class AssemblyMetadataTests
    {
        private static FileVersionInfo BridgeFileInfo()
        {
            Assembly bridge = typeof(Protocol).Assembly;
            return FileVersionInfo.GetVersionInfo(bridge.Location);
        }

        [Fact]
        public void The_assembly_names_the_company_the_product_and_the_version()
        {
            FileVersionInfo info = BridgeFileInfo();

            Assert.Equal("Blue Ridge Automation", info.CompanyName);
            Assert.Equal("MES Zebra Bridge", info.ProductName);
            Assert.StartsWith(Protocol.BridgeVersion, info.FileVersion);
        }

        [Fact]
        public void The_assembly_file_version_tracks_the_protocol_version()
        {
            // A bridge whose exe says 1.0.0 must be the one that answers
            // `bridge=1.0.0`, or a commissioning report means nothing.
            FileVersionInfo info = BridgeFileInfo();
            Assert.Equal(Protocol.BridgeVersion, info.FileMajorPart + "." + info.FileMinorPart + "." + info.FileBuildPart);
        }

        [Fact]
        public void The_bridge_assembly_references_no_third_party_dependency()
        {
            // The two-file deployment depends on this. A PackageReference that
            // lands a DLL in bin/ makes "copy the exe and its conf" a broken install.
            foreach (AssemblyName reference in typeof(Protocol).Assembly.GetReferencedAssemblies())
            {
                bool bcl = reference.Name == "mscorlib"
                        || reference.Name == "System"
                        || reference.Name.StartsWith("System.");
                Assert.True(bcl, "unexpected dependency: " + reference.Name);
            }
        }
    }
}
