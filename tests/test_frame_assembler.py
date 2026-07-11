"""FrameAssembler 单元测试。

验证 daemon 能正确把 termux-sensor 的「多行 pretty-print JSON」
拼装还原为完整帧——这是整个采集链路最关键的解析逻辑。
数据样例直接取自 sensor_test_wear.txt 的真实输出。
"""
import pytest

from hr.daemon import FrameAssembler


# termux-sensor PPG 帧的真实多行输出样例（来自 sensor_test_wear.txt）
PPG_FRAME_LINES = [
    '{\n',
    '  "pah8011_ppg PPG Sensor Non-wakeup": {\n',
    '    "values": [\n',
    '      177156.515625,\n',
    '      143458.40625,\n',
    '      128,\n',
    '      0,\n',
    '      0,\n',
    '      0,\n',
    '      0,\n',
    '      0,\n',
    '      0\n',
    '    ]\n',
    '  }\n',
    '}\n',
]

# 加速度帧的真实样例
ACC_FRAME_LINES = [
    '{\n',
    '  "lsm6dso Accelerometer Non-wakeup": {\n',
    '    "values": [\n',
    '      -0.17218323051929474,\n',
    '      5.250857830047607,\n',
    '      8.313222885131836\n',
    '    ]\n',
    '  }\n',
    '}\n',
]


class TestSingleFrame:
    def test_ppg_frame_assembles_into_one_dict(self):
        """PPG 多行帧应被拼成单个完整 JSON dict。"""
        fa = FrameAssembler()
        frames = []
        for line in PPG_FRAME_LINES:
            frames.extend(fa.feed(line))
        assert len(frames) == 1

    def test_ppg_frame_values_extracted(self):
        """拼装出的帧应能提取出真实 PPG 双通道值。"""
        fa = FrameAssembler()
        frames = []
        for line in PPG_FRAME_LINES:
            frames.extend(fa.feed(line))
        fr = frames[0]
        assert "pah8011_ppg PPG Sensor Non-wakeup" in fr
        vals = fr["pah8011_ppg PPG Sensor Non-wakeup"]["values"]
        assert vals[0] == pytest.approx(177156.515625)
        assert vals[1] == pytest.approx(143458.40625)
        assert vals[2] == 128

    def test_acc_frame_three_axis(self):
        """加速度帧应拼出三轴值。"""
        fa = FrameAssembler()
        frames = []
        for line in ACC_FRAME_LINES:
            frames.extend(fa.feed(line))
        assert len(frames) == 1
        vals = frames[0]["lsm6dso Accelerometer Non-wakeup"]["values"]
        assert len(vals) == 3
        assert vals[0] == pytest.approx(-0.17218323051929474)
        assert vals[1] == pytest.approx(5.250857830047607)
        assert vals[2] == pytest.approx(8.313222885131836)


class TestMultipleFrames:
    def test_two_consecutive_frames(self):
        """连续两帧应各自独立还原，深度归零后开始新帧。"""
        fa = FrameAssembler()
        frames = []
        for line in (PPG_FRAME_LINES + ACC_FRAME_LINES):
            frames.extend(fa.feed(line))
        assert len(frames) == 2
        assert "pah8011_ppg PPG Sensor Non-wakeup" in frames[0]
        assert "lsm6dso Accelerometer Non-wakeup" in frames[1]

    def test_empty_object_frame_skipped(self):
        """空对象帧 {} （termux 启动时先吐的空帧）应被解析为空 dict。"""
        fa = FrameAssembler()
        frames = fa.feed('{}\n')
        assert len(frames) == 1
        assert frames[0] == {}


class TestMalformedInput:
    def test_partial_frame_returns_nothing(self):
        """不完整的帧（大括号未闭合）不应返回帧。"""
        fa = FrameAssembler()
        frames = fa.feed('{\n  "x": {\n    "values": [1]\n')
        assert frames == []

    def test_non_json_garbage_ignored(self):
        """非 JSON 文本（如错误提示行）应被静默忽略，不抛异常。"""
        fa = FrameAssembler()
        # 喂入无大括号的纯文本
        assert fa.feed("No valid sensors were registered!\n") == []
        assert fa.feed("some random text\n") == []

    def test_mixed_text_then_frame(self):
        """错误文本后接正常帧，正常帧仍能被还原。"""
        fa = FrameAssembler()
        frames = []
        for line in ["No valid sensors!\n"] + PPG_FRAME_LINES:
            frames.extend(fa.feed(line))
        assert len(frames) == 1
        assert "pah8011_ppg PPG Sensor Non-wakeup" in frames[0]
