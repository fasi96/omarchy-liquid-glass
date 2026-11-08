import importlib.util
import tempfile
from pathlib import Path
import tomllib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tuner', Path(__file__).resolve().parents[1] / 'tuner/tuner.py')
tuner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tuner)

ALPHA = tuner.defaults()['foot_alpha']
GHOSTTY = f'background-opacity = {ALPHA}'
KITTY = f'background_opacity {ALPHA}'
ALACRITTY = f'background_opacity = {ALPHA}  # omarchy-liquid-glass'
BLOCK = '# omarchy-liquid-glass >>>\n{}\n# <<< omarchy-liquid-glass'


class TerminalSettings(unittest.TestCase):
    """Glass Tuner's see-through background for Ghostty, kitty and Alacritty.

    Everything runs in one temp directory per test: TERMINALS is patched
    wholesale (it holds the paths captured at import time), and so is the
    blocks sha256 ledger, so real configs are never touched."""

    def setUp(self):
        self.ghostty = 'font-family = JetBrains Mono\ntheme = tokyo-night\n'
        self.kitty = 'font_family JetBrains Mono\nforeground #aabbcc\n'
        self.alacritty = '[general]\nimport = ["theme.toml"]\n\n[font]\nsize = 11\n'
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.paths = [self.d / n for n in ('config', 'kitty.conf', 'alacritty.toml')]
        self.pkill = []

    def write(self):
        for path, text in zip(self.paths, (self.ghostty, self.kitty, self.alacritty)):
            path.write_text(text)

    def save(self, glass_on=True):
        """Run _update_terminals over the set-up configs; leave the three file
        texts in self.out."""
        state = tuner.defaults()
        state['glass_on'] = glass_on
        terminals = [(str(p), pre, key, line, cmd) for p, (_, pre, key, line, cmd)
                     in zip(self.paths, tuner.TERMINALS)]
        with patch.object(tuner, 'TERMINALS', terminals), \
             patch.object(tuner, 'ALACRITTY_CONF', str(self.paths[2])), \
             patch.object(tuner, 'CONF_DIR', str(self.d)), \
             patch.object(tuner.blocks, 'HASHES', str(self.d / 'blocks.sha256')), \
             patch.object(tuner.subprocess, 'run') as run:
            tuner._update_terminals(state, create=True)
        self.out = [p.read_text() for p in self.paths]
        self.pkill = [c.args[0] for c in run.call_args_list if c.args and c.args[0][0] == 'pkill']

    def fresh(self):
        self.write()
        self.save()

    def test_writes_one_managed_block_per_terminal(self):
        self.fresh()
        ghostty, kitty, alacritty = self.out
        self.assertIn(BLOCK.format(GHOSTTY), ghostty)
        self.assertTrue(ghostty.endswith('# <<< omarchy-liquid-glass\n'))   # appended at the end
        self.assertIn(BLOCK.format(KITTY), kitty)
        self.assertIn(ALACRITTY, alacritty)                                 # right under [general]
        self.assertLess(alacritty.index(ALACRITTY), alacritty.index('[font]'))
        tomllib.loads(alacritty)                                            # still valid TOML

    def test_save_twice_is_idempotent_and_does_not_resignal(self):
        self.fresh()
        first = self.out
        self.ghostty, self.kitty, self.alacritty = first
        self.save()
        self.assertEqual(self.out, first)
        self.assertEqual(self.pkill, [])        # nothing changed: no reload needed

    def test_your_own_opacity_setting_is_left_in_charge(self):
        self.ghostty = 'theme = tokyo-night\nbackground-opacity = 0.9\n'
        self.kitty = 'background_opacity 0.8\n'                 # kitty writes "key value"
        self.alacritty = '[general]\nbackground_opacity = 0.85\n'
        self.write()
        self.save()
        for text in self.out:
            self.assertNotIn('omarchy-liquid-glass', text)
        self.assertIn('background-opacity = 0.9', self.out[0])
        self.assertIn('background_opacity 0.8', self.out[1])
        self.assertIn('background_opacity = 0.85', self.out[2])

    def test_off_removes_ours_but_not_yours(self):
        self.fresh()
        self.ghostty = BLOCK.format(GHOSTTY) + '\nbackground-opacity = 0.9\n'
        self.alacritty = '[general]\nimport = ["theme.toml"]\n' + ALACRITTY + '\n'
        self.write()
        self.save(glass_on=False)
        ghostty, _, alacritty = self.out
        self.assertNotIn('omarchy-liquid-glass', ghostty)
        self.assertIn('background-opacity = 0.9', ghostty)      # your line stays
        self.assertNotIn('omarchy-liquid-glass', alacritty)
        self.assertIn('import = ["theme.toml"]', alacritty)     # the rest of your file too
        tomllib.loads(alacritty)

    def test_alacritty_top_level_key_lands_before_any_table(self):
        self.alacritty = 'font.size = 11\n\n[window]\nopacity = 1\n'
        self.write()
        self.save()
        self.assertTrue(self.out[2].startswith(ALACRITTY))      # top-level scope
        tomllib.loads(self.out[2])

    def test_broken_toml_is_never_touched(self):
        self.alacritty = '[general]\nthis is not toml\n'
        self.write()
        self.save()
        self.assertEqual(self.out[2], self.alacritty)

    def test_kitty_gets_a_reload_signal_when_its_config_changed(self):
        self.fresh()
        self.assertEqual(self.pkill, [['pkill', '-USR1', '-x', 'kitty']])
        self.ghostty, self.kitty, self.alacritty = self.out
        self.save(glass_on=False)               # removing our block changed it again
        self.assertEqual(self.pkill, [['pkill', '-USR1', '-x', 'kitty']])

    def test_missing_configs_are_not_created(self):
        with patch.object(tuner, 'TERMINALS',
                          [(str(p), pre, key, line, cmd) for p, (_, pre, key, line, cmd)
                           in zip(self.paths, tuner.TERMINALS)]), \
             patch.object(tuner, 'ALACRITTY_CONF', str(self.paths[2])), \
             patch.object(tuner, 'CONF_DIR', str(self.d)):
            tuner._update_terminals(tuner.defaults(), create=True)
        self.assertEqual(list(self.d.iterdir()), [])            # nothing written anywhere

    def test_uninstall_removes_only_our_lines(self):
        self.fresh()
        ghostty_before, kitty_before, alacritty_before = self.out
        ghostty_before += 'font-size = 13\n'
        alacritty_before += 'colors = 1\n'
        for path, text in zip(self.paths, (ghostty_before, kitty_before, alacritty_before)):
            path.write_text(text)
        with patch.object(tuner, 'TERMINALS',
                          [(str(p), pre, key, line, cmd) for p, (_, pre, key, line, cmd)
                           in zip(self.paths, tuner.TERMINALS)]), \
             patch.object(tuner, 'ALACRITTY_CONF', str(self.paths[2])), \
             patch.object(tuner.blocks, 'HASHES', str(self.d / 'blocks.sha256')):
            tuner.remove_terminal_settings()
        self.assertEqual(self.paths[0].read_text(), self.ghostty + 'font-size = 13\n')
        self.assertEqual(self.paths[1].read_text(), self.kitty)                 # back to your lines only
        self.assertEqual(self.paths[2].read_text(), self.alacritty + 'colors = 1\n')


if __name__ == '__main__':
    unittest.main()
