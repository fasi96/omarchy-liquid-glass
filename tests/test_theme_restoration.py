import contextlib
import importlib.util
import io
import json
import tempfile
from types import SimpleNamespace
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tuner', Path(__file__).resolve().parents[1] / 'tuner/tuner.py')
tuner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tuner)


class TunerTests(unittest.TestCase):
    def setUp(self):
        for name, value in {'_last_alpha': [None], '_last_text': [None],
                            '_last_bg': [None], '_live': {'state': None}}.items():
            patcher = patch.object(tuner, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_off_removes_all_managed_terminal_overrides(self):
        state = tuner.defaults()
        user = '[main]\nfont=User Font:size=11\npad=14x14\n[colors-dark]\nalpha=0.9\n'
        glass = tuner.write_foot(state, user)
        state['glass_on'] = False
        self.assertEqual(tuner.write_foot(state, glass), user)

    def test_off_does_not_override_theme_borders_or_animations(self):
        state = tuner.defaults()
        state.update(glass_on=False, border_spin=True, glass_border=False)
        self.assertEqual(tuner.look_lua(state), '')
        self.assertIn('materialize_duration = 0.0', tuner.light_lua(state))

    def test_off_restores_included_theme_and_user_alpha(self):
        with tempfile.TemporaryDirectory() as directory:
            theme = Path(directory) / 'theme.ini'
            theme.write_text('[colors-dark]\nforeground=aabbcc\nbackground=112233\nalpha=0.8\n')
            foot = Path(directory) / 'foot.ini'
            base = f'[main]\ninclude={theme}\n[colors-dark]\nalpha=0.9\n'
            foot.write_text(tuner.write_foot(tuner.defaults(), base))
            with patch.object(tuner, 'FOOT_INI', str(foot)):
                self.assertEqual(tuner.base_foot_colors(), (0.9, 'aabbcc', '112233'))

    def test_off_syncs_original_colours_instead_of_glass_transparency(self):
        state = tuner.defaults()
        state.update(glass_on=False, foot_alpha=0.25, text_boost=1)
        with patch.object(tuner, 'base_foot_colors', return_value=(1, 'aabbcc', '112233')), patch.object(tuner, 'push_foot_alpha') as alpha, patch.object(tuner, 'push_foot_text') as text:
            tuner.sync_foot(state, force=True)
        alpha.assert_called_once_with(1, '112233')
        text.assert_called_once_with(0, 'aabbcc')

    def test_toggle_restores_config_and_retains_saved_tuning(self):
        state = tuner.defaults()
        state.update(glass_on=True, foot_alpha=0.25, border_spin=True,
                     glass_border=False, text_boost=0.8)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            foot = directory / 'foot.ini'
            user = '[main]\nfont=User Font:size=11\n[colors-dark]\nalpha=0.9\nforeground=aabbcc\nbackground=112233\n'
            foot.write_text(tuner.write_foot(state, user))
            state_file = directory / 'state.json'
            state_file.write_text(json.dumps(state))
            lua = directory / 'liquid_glass.lua'
            with contextlib.ExitStack() as stack:
                for name, value in {'CONF_DIR': str(directory), 'STATE_FILE': str(state_file),
                                    'LUA_FILE': str(lua), 'FOOT_INI': str(foot),
                                    'blocks': None}.items():
                    stack.enter_context(patch.object(tuner, name, value))
                stack.enter_context(patch.object(tuner, 'theme_state_file', return_value=None))
                stack.enter_context(patch.object(tuner, 'edge_supported', return_value=False))
                stack.enter_context(patch.object(tuner, 'light_supported', return_value=False))
                run = stack.enter_context(patch.object(tuner.subprocess, 'run', return_value=SimpleNamespace(stdout='')))
                stack.enter_context(patch.object(tuner, 'hypr_eval'))
                alpha = stack.enter_context(patch.object(tuner, 'push_foot_alpha'))
                text = stack.enter_context(patch.object(tuner, 'push_foot_text'))
                stack.enter_context(patch.object(tuner.sys, 'argv', ['tuner.py', '--toggle']))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                tuner.main()
                self.assertEqual(foot.read_text(), user)
                generated = lua.read_text()
                for override in ('active_border', 'borderangle', 'rounding', 'gaps_in', '+hyprglass_enabled'):
                    self.assertNotIn(override, generated)
                saved = json.loads(state_file.read_text())
                self.assertEqual(saved, dict(state, glass_on=False))
                alpha.assert_called_once_with(0.9, '112233')
                text.assert_called_once_with(0, 'aabbcc')
                self.assertIn(['hyprctl', 'reload'], [call.args[0] for call in run.call_args_list])

                alpha.reset_mock()
                text.reset_mock()
                tuner.main()
                self.assertEqual(json.loads(state_file.read_text()), state)
                self.assertIn('active_border', lua.read_text())
                self.assertIn('alpha=0.25', foot.read_text())
                alpha.assert_called_once_with(0.25, tuner.foot_bg())
                text.assert_called_once_with(0, tuner.text_color(0.8))

    def test_theme_hook_while_off_keeps_original_terminal_colors(self):
        state = tuner.defaults()
        state['glass_on'] = False
        with patch.object(tuner, 'load_state', return_value=state), \
             patch.object(tuner, 'theme_state_file', return_value='/theme/state.json'), \
             patch.object(tuner, '_mark_themed'), \
             patch.object(tuner, 'save') as save, \
             patch.object(tuner, 'base_foot_colors', return_value=(0.9, 'aabbcc', '112233')), \
             patch.object(tuner, 'push_foot_alpha') as alpha, \
             patch.object(tuner, 'push_foot_text') as text:
            tuner.theme_hook()
        save.assert_called_once_with(state, persist=False)
        alpha.assert_called_once_with(0.9, '112233')
        text.assert_called_once_with(0, 'aabbcc')


if __name__ == '__main__':
    unittest.main()
