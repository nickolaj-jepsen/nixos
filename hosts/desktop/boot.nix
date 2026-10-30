{
  nixos = {pkgs, ...}: {
    boot.loader.systemd-boot = {
      # Windows' ESP is on the NVMe, which systemd-boot can't chainload across. The
      # stock `windows.<n>.efiDeviceHandle` hardcodes a shell handle (HD1d) that shifts
      # with firmware disk enumeration; instead a dedicated shell copy runs the
      # startup.nsh beside it, which connects every disk and searches for bootmgfw.efi.
      extraFiles = {
        "efi/windows/shell.efi" = "${pkgs.edk2-uefi-shell}/shell.efi";
        "efi/windows/startup.nsh" = pkgs.writeText "startup.nsh" ''
          @echo -off
          connect -r
          map -r
          for %a run (0 15)
            if exist fs%a:\EFI\Microsoft\Boot\bootmgfw.efi then
              fs%a:\EFI\Microsoft\Boot\bootmgfw.efi
            endif
          endfor
          echo "bootmgfw.efi not found on any filesystem; 'map' lists them, 'exit' returns to systemd-boot"
        '';
      };
      extraEntries."windows_11.conf" = ''
        title Windows 11
        efi /efi/windows/shell.efi
        options -nointerrupt -nomap -noversion
        sort-key o_windows_11
      '';
      # 512 MB ESP: a 4th kernel version overflows the FAT mid-write; 3 peaks at ~84%.
      configurationLimit = 3;
    };
  };
}
