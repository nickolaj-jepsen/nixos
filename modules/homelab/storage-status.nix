# Disk/RAID/backup health as one JSON file for the Glance "Storage" widget. Grafana Cloud
# alerts on the same signals; this is the glanceable view, read on demand, never pushed.
{
  flake.modules.nixos.storage-status = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Dedup by device so the btrfs subvolumes sharing / are listed once ("/" sorts first).
    realFs = lib.filterAttrs (_: fs: lib.elem fs.fsType ["ext4" "btrfs" "vfat" "fuse.mergerfs"]) config.fileSystems;
    mountPerDevice = lib.listToAttrs (lib.mapAttrsToList (m: fs: lib.nameValuePair fs.device m) realFs);
    mounts = lib.sort lib.lessThan (lib.attrValues mountPerDevice);
    btrfsMounts = lib.attrValues (lib.filterAttrs (_d: m: realFs.${m}.fsType == "btrfs") mountPerDevice);
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      systemd.services.storage-status = {
        description = "Write disk, RAID and backup health for the Glance dashboard";
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "homelab-status";
          StateDirectoryMode = "0755";
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "storage-status";
            runtimeInputs = with pkgs; [coreutils jq smartmontools util-linux btrfs-progs systemd gawk gnused];
            text = ''
              out=/var/lib/homelab-status/storage.json
              mounts=(${lib.escapeShellArgs mounts})
              btrfsMounts=(${lib.escapeShellArgs btrfsMounts})
              rows='[]'
              # row GROUP NAME DETAIL STATUS(ok|warn|bad|idle) [EPOCH]; idle = shown nowhere, counted only
              row() {
                rows=$(jq -c --arg g "$1" --arg n "$2" --arg d "$3" --arg s "$4" --arg t "''${5:-}" \
                  '. + [{group: $g, name: $n, detail: $d, status: $s} + (if $t == "" then {} else {time: $t} end)]' <<<"$rows")
              }
              epoch() { [ -n "$1" ] && [ "$1" != n/a ] && date -d "$1" +%s 2>/dev/null || true; }

              # ---- backups ----------------------------------------------------------
              now=$(date +%s)
              last=$(awk '/^homelab_restic_last_success_timestamp_seconds/ {print $2}' \
                /var/lib/node-exporter-textfile/restic.prom 2>/dev/null || true)
              state=$(systemctl show restic-backups-homelab.service -p ActiveState --value)
              if [ "$state" = failed ]; then
                row Backups Restic "last run failed, last success" bad "$last"
              elif [ -z "$last" ]; then
                row Backups Restic "no successful run recorded" bad
              elif [ "$state" = activating ]; then
                row Backups Restic "running now, last success" ok "$last"
              else
                age=$(( (now - last) / 3600 ))
                # Same 40 h line as the Grafana BackupStale alert.
                if [ "$age" -ge 40 ]; then s=bad; elif [ "$age" -ge 26 ]; then s=warn; else s=ok; fi
                row Backups Restic "last success" "$s" "$last"
              fi
              resticTime=''${last:-}
              # The pre-backup dumps are whatever restic Wants=; their state resets at reboot.
              for unit in $(systemctl show restic-backups-homelab.service -p Wants --value); do
                case "$unit" in *.service) ;; *) continue ;; esac
                st=$(systemctl show "$unit" -p ActiveState --value)
                res=$(systemctl show "$unit" -p Result --value)
                ts=$(systemctl show "$unit" -p ExecMainExitTimestamp --value)
                name=''${unit%.service}
                if [ "$st" = failed ]; then
                  row Backups "$name" "failed ($res)" bad "$(epoch "$ts")"
                elif [ -n "$ts" ]; then
                  row Backups "$name" "ok" ok "$(epoch "$ts")"
                else
                  row Backups "$name" "not run since boot" ok
                fi
              done

              # ---- RAID -------------------------------------------------------------
              for link in /dev/md/*; do
                [ -e "$link" ] || continue
                md=$(basename "$(readlink -f "$link")")
                sys=/sys/block/$md/md
                total=$(cat "$sys/raid_disks"); degraded=$(cat "$sys/degraded")
                action=$(cat "$sys/sync_action"); done_=$(cat "$sys/sync_completed")
                mount=$(findmnt -nro TARGET -S "/dev/$md" | head -n1 || true)
                detail="$(( total - degraded ))/$total mirrors · $md''${mount:+ · $mount}"
                if [ "$action" != idle ]; then
                  pct=$(awk -F' */ *' 'NF == 2 && $2 > 0 {printf "%d%%", $1 * 100 / $2}' <<<"$done_")
                  row RAID "$(basename "$link")" "$detail · $action ''${pct:-}" warn
                elif [ "$degraded" -gt 0 ]; then
                  row RAID "$(basename "$link")" "$detail · degraded" bad
                else
                  row RAID "$(basename "$link")" "$detail" ok
                fi
              done

              # ---- disks (by serial: sdX letters move between boots) -----------------
              while read -r dev; do
                info=$(lsblk -J -o NAME,SERIAL,MODEL,SIZE,MOUNTPOINTS "$dev")
                serial=$(jq -r '.blockdevices[0].serial // "?"' <<<"$info")
                model=$(jq -r '.blockdevices[0].model // "?" | gsub("^\\s+|\\s+$"; "")' <<<"$info")
                size=$(jq -r '.blockdevices[0].size' <<<"$info")
                role=$(jq -r '[.. | .mountpoints? // empty | .[] | select(. != null)] | unique
                  | if any(. == "/") then "system" elif length == 0 then "unused" else map(ltrimstr("/mnt/")) | join(", ") end' <<<"$info")
                smart=$(smartctl -j -a "$dev" 2>/dev/null || true)
                read -r passed temp hours realloc pending uncorr < <(jq -r '
                  ([.ata_smart_attributes.table[]? | {(.id | tostring): .raw.value}] | add // {}) as $a
                  | [(.smart_status.passed | if . == null then "null" else . end), .temperature.current // "?", .power_on_time.hours // 0,
                     $a["5"] // 0, $a["197"] // 0, $a["198"] // 0] | map(tostring) | join(" ")' <<<"$smart")
                detail="$model · $size · ''${temp}°C · $(( hours / 8766 ))y powered on"
                [ "$realloc" -eq 0 ] || detail="$detail · $realloc reallocated"
                [ "$pending" -eq 0 ] || detail="$detail · $pending pending"
                [ "$uncorr" -eq 0 ] || detail="$detail · $uncorr uncorrectable"
                # Nothing on an unmounted disk is at risk: only an outright SMART failure is worth a look.
                if [ "$role" = unused ]; then
                  if [ "$passed" = false ]; then s=warn; else s=idle; fi
                elif [ "$passed" = false ] || [ "$pending" -gt 0 ] || [ "$uncorr" -gt 0 ]; then s=bad
                elif [ "$passed" = null ] || [ "$realloc" -gt 0 ]; then s=warn
                else s=ok; fi
                row Disks "$role ($serial)" "$detail" "$s"
              done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" && $1 ~ /\/sd/ {print $1}')

              # ---- filesystems -------------------------------------------------------
              fullest="" fullestPct=-1 scrubTime=""
              for m in "''${mounts[@]}"; do
                if ! mountpoint -q "$m"; then
                  row Filesystems "$m" "not mounted" bad
                  continue
                fi
                read -r avail pcent < <(df -B1 --output=avail,pcent "$m" | tail -n1)
                pct=''${pcent%\%}
                # Same lines as the HostDiskFilling (85%) and HostOutOfDiskSpace (95%) alerts.
                if [ "$pct" -ge 95 ]; then s=bad; elif [ "$pct" -ge 85 ]; then s=warn; else s=ok; fi
                if [ "$pct" -gt "$fullestPct" ]; then fullest=$m fullestPct=$pct; fi
                row Filesystems "$m" "$pct% used · $(numfmt --to=iec --suffix=B "$avail") free" "$s"
              done
              for m in "''${btrfsMounts[@]}"; do
                scrub=$(btrfs scrub status "$m" 2>/dev/null || true)
                started=$(sed -n 's/^Scrub started: *//p' <<<"$scrub")
                status=$(sed -n 's/^Status: *//p' <<<"$scrub")
                summary=$(sed -n 's/^Error summary: *//p' <<<"$scrub")
                devErrs=$(btrfs device stats "$m" 2>/dev/null | awk '{s += $2} END {print s + 0}')
                scrubTime=$(epoch "$started")
                if [ "$devErrs" -gt 0 ]; then
                  row Filesystems "Scrub $m" "$devErrs btrfs device errors" bad "$(epoch "$started")"
                elif [ -z "$started" ]; then
                  row Filesystems "Scrub $m" "never scrubbed" warn
                elif [ "$summary" != "no errors found" ]; then
                  row Filesystems "Scrub $m" "$summary" bad "$(epoch "$started")"
                elif [ "$status" != finished ] && [ "$status" != running ]; then
                  row Filesystems "Scrub $m" "$status" warn "$(epoch "$started")"
                else
                  row Filesystems "Scrub $m" "$status, no errors" ok "$(epoch "$started")"
                fi
              done

              # One summary line per group; the template lists only the rows that need attention.
              jq -n --argjson rows "$rows" --arg updated "$now" --arg restic "$resticTime" \
                --arg fullest "$fullest" --arg fullestPct "$fullestPct" --arg scrub "$scrubTime" '
                def worst: map(.status) | if index("bad") then "bad" elif index("warn") then "warn" else "ok" end;
                def count(s): map(select(.status == s)) | length;
                {
                  updated: $updated,
                  rows: $rows,
                  groups: [
                    ($rows | map(select(.group == "Backups")) | {name: "Backups", status: worst, summary: "last success", time: $restic}),
                    ($rows | map(select(.group == "RAID")) | {name: "RAID", status: worst, summary: "\(count("ok"))/\(length) arrays mirrored"}),
                    ($rows | map(select(.group == "Disks")) | {name: "Disks", status: worst,
                      summary: ("\(count("ok"))/\(length - count("idle")) healthy" + (if count("idle") > 0 then " · \(count("idle")) unused" else "" end))}),
                    ($rows | map(select(.group == "Filesystems")) | {name: "Filesystems", status: worst,
                      summary: ("fullest \($fullest) \($fullestPct)% · scrubbed"), time: $scrub})
                  ] | map(if .time == "" then del(.time) else . end)
                }' >"$out.tmp"
              mv "$out.tmp" "$out"
            '';
          });
        };
      };
      systemd.timers.storage-status = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "5min";
        };
      };

      # Loopback only, next to the stub_status endpoint; Glance fetches it server-side.
      services.nginx.virtualHosts."status.localhost".locations."= /storage.json".extraConfig = ''
        alias /var/lib/homelab-status/storage.json;
        default_type application/json;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
      '';
    };
  };
}
