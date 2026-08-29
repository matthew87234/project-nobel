import os

repo_root = os.path.abspath('.')
src_dir = os.path.join(repo_root, 'swiftui-version')
staging_dir = os.path.join(repo_root, '.build_dmg_staging')

volume_name = 'Project Nobel'
format = 'UDZO'
compression_level = 9

files = [
    os.path.join(staging_dir, 'Project Nobel.app')
]

symlinks = {
    'Applications': '/Applications'
}

badge_icon = os.path.join(src_dir, 'Resources', 'AppIcon.icns')
background = os.path.join(repo_root, 'dmg_background.png')

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

window_rect = ((200, 120), (660, 400))
default_view = 'icon-view'

icon_size = 120
text_size = 13

icon_locations = {
    'Project Nobel.app': (160, 200),
    'Applications': (500, 200)
}
