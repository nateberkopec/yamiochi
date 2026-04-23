#!/usr/bin/env fish

set script_dir (cd (dirname (status --current-filename)); pwd)
set output "$script_dir/../ansible/.secrets/factory.env"
set tmp_json (mktemp)

cd "$script_dir"
fnox export --format json > "$tmp_json"
python3 "$script_dir/materialize_factory_env.py" "$tmp_json" "$output"
rm -f "$tmp_json"

if command -sq gum
    gum style --foreground 212 --bold "Wrote $output"
else
    echo "Wrote $output"
end
