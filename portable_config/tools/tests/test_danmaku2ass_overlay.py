import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


CONVERTER = Path(__file__).resolve().parents[1] / 'danmaku2ass.py'
SPEC = importlib.util.spec_from_file_location('danmaku2ass', CONVERTER)
danmaku2ass = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(danmaku2ass)


SAMPLE_XML = '''<?xml version="1.0" encoding="UTF-8"?><i>
<d p="1,1,25,16777215,0,0,1,0">scroll</d>
<d p="2,4,25,16711680,0,0,2,0">bottom</d>
<d p="3,5,25,65280,0,0,3,0">top</d>
<d p="4,6,25,255,0,0,4,0">reverse</d>
<d p="5,7,25,16777215,0,0,5,0">[0,0,1,1,1,1,1,1,1,1,1,1,1,1,1]</d>
</i>'''


class OverlayManifestTest(unittest.TestCase):
    def test_writes_standard_bilibili_modes_and_counts_advanced(self):
        with tempfile.TemporaryDirectory() as directory:
            xml_path = Path(directory) / 'comments.xml'
            manifest_path = Path(directory) / 'comments.json'
            xml_path.write_text(SAMPLE_XML, encoding='utf-8')

            danmaku2ass.Danmaku2ASS(
                str(xml_path), 'Bilibili', None, 1920, 1080,
                reserve_blank=810, font_face='Microsoft YaHei', font_size=45,
                text_opacity=0.5, duration_marquee=8, duration_still=5,
                is_reduce_comments=True, overlay_output=str(manifest_path),
            )

            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            self.assertEqual(1, manifest['version'])
            self.assertEqual({'width': 1920, 'height': 1080, 'font': 'Microsoft YaHei', 'font_size': 45, 'opacity': 0.5, 'outline': 1.8}, manifest['stage'])
            self.assertEqual(0, manifest['dropped'])
            self.assertEqual(1, manifest['skipped_advanced'])

            events = manifest['events']
            self.assertEqual(['rtl', 'bottom', 'top', 'ltr'], [event['mode'] for event in events])
            self.assertEqual([1.0, 2.0, 3.0, 4.0], [event['start'] for event in events])
            self.assertEqual([9.0, 7.0, 8.0, 12.0], [event['end'] for event in events])
            self.assertEqual(1920, events[0]['x_start'])
            self.assertLess(events[0]['x_end'], 0)
            self.assertEqual(0xFF0000, events[1]['color'])
            self.assertEqual(45.0, events[2]['font_size'])

    def test_default_ass_output_remains_available(self):
        with tempfile.TemporaryDirectory() as directory:
            xml_path = Path(directory) / 'comments.xml'
            ass_path = Path(directory) / 'comments.ass'
            xml_path.write_text(SAMPLE_XML, encoding='utf-8')

            danmaku2ass.Danmaku2ASS(str(xml_path), 'Bilibili', str(ass_path), 1920, 1080)

            ass = ass_path.read_text(encoding='utf-8-sig')
            self.assertIn('[Script Info]', ass)
            self.assertIn('\\move(', ass)


if __name__ == '__main__':
    unittest.main()
