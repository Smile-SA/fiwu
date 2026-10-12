Name:           fiwu
Version:        1.0.0
Release:        1%{?dist}
Summary:        Per-process egress firewall for Linux with UI prompts

# NetfilterQueue's C extension is fetched/compiled via pip+cython inside
# the %%install step, outside rpmbuild's tracked %%build source tree -
# there's no matching source for an automatic -debugsource package, which
# otherwise fails the build with an empty %%files list for debugsource.
%global debug_package %{nil}

License:        APACHE 2.0
URL:            https://github.com/smile-sa/fiwu
Source0:        %{name}-%{version}.tar.gz
# fiwu.service and fiwu-toggle.sudoers live outside src/fiwu/, so they
# are NOT part of the python sdist built by `python3 -m build --sdist`.
# build.sh copies these into SOURCES/ alongside the sdist tarball.
Source1:        fiwu.service
Source2:        fiwu-toggle.sudoers

# Architecture: any (contains a C extension: NetfilterQueue is built
# for the build host architecture)

BuildRequires:  gcc
BuildRequires:  python3-devel
BuildRequires:  python3-pip
BuildRequires:  python3-Cython
BuildRequires:  pyproject-rpm-macros
BuildRequires:  pkgconfig(libnetfilter_queue)
BuildRequires:  systemd-rpm-macros

Requires:       python3
Requires:       python3-scapy
Requires:       python3-psutil
Requires:       python3-tkinter
Requires:       iproute
Requires:       iptables
Requires:       dbus-x11
Requires:       gnome-extensions-app
Requires:       gnome-tweaks
Requires:       libnetfilter_queue

Obsoletes:      python3-netfilterqueue < %{version}-%{release}
Conflicts:      python3-netfilterqueue

%{?systemd_requires}

%description
Fiwu intercepts outgoing network connections via NFQUEUE and prompts the
user to allow or block each process on first contact. Supports permanent
and session-only decisions with a tkinter GUI and a GNOME shell extension
for quick enable/disable from the system menu.

%prep
%autosetup -n %{name}-%{version}

%generate_buildrequires
%pyproject_buildrequires

%build
%pyproject_wheel

%install
%pyproject_install
%pyproject_save_files fiwu

# NetfilterQueue: same two-step fallback as debian/rules -
# try a normal wheel build first, re-cythonize against this
# interpreter's C-API if that fails.
if ! %{python3} -m pip install --no-cache-dir --no-deps --no-build-isolation \
        --target %{buildroot}%{python3_sitelib} NetfilterQueue 2>/dev/null; then
    echo "Standard build failed. Re-cythonizing NetfilterQueue..."
    mkdir -p %{_builddir}/nfq_build
    %{python3} -m pip download --no-deps --no-binary :all: --no-build-isolation \
        -d %{_builddir}/nfq_build NetfilterQueue
    tar -xzf %{_builddir}/nfq_build/NetfilterQueue-*.tar.gz -C %{_builddir}/nfq_build
    ( cd %{_builddir}/nfq_build/NetfilterQueue-* && \
      cython3 netfilterqueue/_impl.pyx && \
      %{python3} -m pip install . --no-deps --no-build-isolation \
          --target %{buildroot}%{python3_sitelib} )
    rm -rf %{_builddir}/nfq_build
fi

# Configuration & service unit (mirrors override_dh_auto_install)
install -D -m 664 src/fiwu/config.json %{buildroot}%{_sysconfdir}/fiwu/config.json
install -D -m 644 %{SOURCE1} %{buildroot}%{_unitdir}/fiwu.service
install -D -m 0440 %{SOURCE2} %{buildroot}%{_sysconfdir}/sudoers.d/fiwu-toggle

# AppArmor profile: optional. Fedora targets use SELinux by default,
# but the AppArmor profile will be installed if the file is present
# in the source tarball and the target provides AppArmor userspace.
if [ -f fiwu-apparmor-profile ]; then
    install -D -m 644 fiwu-apparmor-profile %{buildroot}%{_sysconfdir}/apparmor.d/fiwu
fi

# GNOME Shell extension
mkdir -p %{buildroot}%{_datadir}/gnome-shell/extensions/fiwu-toggle@rnd.smile.fr
cp -r src/fiwu/gui/extension/. %{buildroot}%{_datadir}/gnome-shell/extensions/fiwu-toggle@rnd.smile.fr/

%post
%systemd_post fiwu.service

%preun
%systemd_preun fiwu.service

%postun
%systemd_postun_with_restart fiwu.service

%files -f %{pyproject_files}
%{_bindir}/fiwu
%{_bindir}/fiwu-daemon
# NetfilterQueue is pip-installed by hand above, outside the fiwu
# distribution tracked by the pyproject-save-files helper macro, so it
# isn't auto-included. Glob the dist-info dir since the version isn't
# pinned above.
%{python3_sitelib}/netfilterqueue/
%{python3_sitelib}/netfilterqueue-*.dist-info/
%config(noreplace) %{_sysconfdir}/fiwu/config.json
%attr(0440,root,root) %{_sysconfdir}/sudoers.d/fiwu-toggle
%{_unitdir}/fiwu.service
%{_datadir}/gnome-shell/extensions/fiwu-toggle@rnd.smile.fr/
# AppArmor profile path - add back here (uncommented) if you re-enable
# the fiwu-apparmor-profile install step above.

%changelog
* Mon 22 06 2026 Saifuddin Mohammad <saifuddin.mohammad@smile.fr> - 0.7.6.4
- Initial RPM packaging, translated from debian/control + debian/rules