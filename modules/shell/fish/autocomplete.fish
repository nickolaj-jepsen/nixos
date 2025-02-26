# ds autocomplete (if its installed)
if type -q ds
    _DS_COMPLETE=fish_source ds | source;
end;