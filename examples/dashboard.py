#!/usr/bin/env python3
"""Interactive PyQt5 dashboard demo for the PYNQ framebuffer.

Run as root on the board:
    QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0 /usr/bin/python3 examples/dashboard.py [options]

What it shows:
  * an image slideshow; images are decoded and scaled in a background thread and
    cross-faded with an animation,
  * a live chart of CPU load and chip temperature (Zynq XADC),
  * KPI tiles whose values animate when they change,
  * a spinner driven at 60 Hz; its measured frame rate ("UI fps") shows how smooth
    the UI really is.

Controls: click the image or use Left/Right to change images, Space to pause,
Q or Esc to quit.

Options:
  --images DIR      directory searched (recursively) for .jpg/.jpeg/.png
                    (default: /home/xilinx/jupyter_notebooks)
  --interval SEC    slideshow interval (default: 4)
  --duration SEC    quit automatically after SEC seconds (for benchmarking)
  --stats SEC       print performance stats to stdout every SEC seconds (default: 5)
"""
import argparse
import glob
import math
import os
import sys
import time
from collections import deque

from PyQt5.QtCore import (QEasingCurve, QObject, QPointF, QRectF, QRunnable, QSize, Qt,
                          QThreadPool, QTimer, QVariantAnimation, pyqtSignal)
from PyQt5.QtGui import QColor, QFont, QImage, QPainter, QPainterPath, QPen, QPixmap
from PyQt5.QtWidgets import (QApplication, QGridLayout, QHBoxLayout, QLabel, QPushButton,
                             QVBoxLayout, QWidget)

BG = "#14161a"
CARD = "#1e2127"
TEXT = "#e6e8eb"
MUTED = "#8a9099"
ACCENT = "#4c9aff"
ACCENT2 = "#f5a623"


# ---------------------------------------------------------------- system metrics
class Metrics:
    """Reads CPU load, memory and Zynq XADC temperature from procfs/sysfs."""

    def __init__(self):
        self._prev = self._cpu_times()
        self._xadc = next(iter(glob.glob("/sys/bus/iio/devices/iio:device*/in_temp0_raw")), None)

    @staticmethod
    def _cpu_times():
        with open("/proc/stat") as f:
            vals = [int(v) for v in f.readline().split()[1:]]
        idle = vals[3] + vals[4]
        return sum(vals), idle

    def cpu_percent(self):
        total, idle = self._cpu_times()
        dt, di = total - self._prev[0], idle - self._prev[1]
        self._prev = (total, idle)
        return 100.0 * (1.0 - di / dt) if dt > 0 else 0.0

    @staticmethod
    def mem_used_mb():
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0])
        return (info["MemTotal"] - info["MemAvailable"]) / 1024.0

    def temperature_c(self):
        if not self._xadc:
            return float("nan")
        d = os.path.dirname(self._xadc)
        try:
            raw = float(open(self._xadc).read())
            offset = float(open(os.path.join(d, "in_temp0_offset")).read())
            scale = float(open(os.path.join(d, "in_temp0_scale")).read())
            return (raw + offset) * scale / 1000.0
        except (OSError, ValueError):
            return float("nan")


# ---------------------------------------------------------------- background image loading
class LoaderSignals(QObject):
    loaded = pyqtSignal(int, QImage, str, float)


class ImageLoadTask(QRunnable):
    """Decodes and scales one image off the GUI thread (QImage is thread-safe, QPixmap is not)."""

    def __init__(self, token, path, size, signals):
        super().__init__()
        self.token, self.path, self.size, self.signals = token, path, size, signals

    def run(self):
        t0 = time.monotonic()
        img = QImage(self.path)
        if not img.isNull():
            img = img.scaled(self.size, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            img = img.convertToFormat(QImage.Format_RGB32)
        self.signals.loaded.emit(self.token, img, self.path, time.monotonic() - t0)


class ImageView(QWidget):
    """Shows images with an animated cross-fade."""

    clicked = pyqtSignal()

    def __init__(self, paths):
        super().__init__()
        self.paths = paths
        self.index = -1
        self.current = QPixmap()
        self.previous = QPixmap()
        self.fade = 1.0
        self.caption = ""
        self.load_times = deque(maxlen=20)
        self._token = 0
        self._pool = QThreadPool.globalInstance()
        self._signals = LoaderSignals()
        self._signals.loaded.connect(self._on_loaded)
        self._anim = QVariantAnimation(self, startValue=0.0, endValue=1.0, duration=600,
                                       easingCurve=QEasingCurve.InOutQuad)
        self._anim.valueChanged.connect(self._on_fade)
        self.setMinimumSize(QSize(320, 240))

    def show_relative(self, step):
        if not self.paths:
            return
        self.index = (self.index + step) % len(self.paths)
        self._token += 1
        self._pool.start(ImageLoadTask(self._token, self.paths[self.index], self.size(), self._signals))

    def _on_loaded(self, token, img, path, seconds):
        if token != self._token or img.isNull():
            return  # superseded by a newer request, or unreadable
        self.load_times.append(seconds)
        self.previous = self.current
        self.current = QPixmap.fromImage(img)
        self.caption = f"{os.path.basename(path)}  ({self.index + 1}/{len(self.paths)})"
        self._anim.stop()
        self._anim.start()

    def _on_fade(self, value):
        self.fade = value
        self.update()

    def mousePressEvent(self, event):
        self.clicked.emit()

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#000000"))
        for pix, opacity in ((self.previous, 1.0 - self.fade), (self.current, self.fade)):
            if pix.isNull() or opacity <= 0.0:
                continue
            p.setOpacity(opacity)
            x = (self.width() - pix.width()) // 2
            y = (self.height() - pix.height()) // 2
            p.drawPixmap(x, y, pix)
        p.setOpacity(1.0)
        if self.caption:
            p.fillRect(0, self.height() - 34, self.width(), 34, QColor(0, 0, 0, 160))
            p.setPen(QColor(TEXT))
            p.drawText(QRectF(12, self.height() - 34, self.width() - 24, 34),
                       Qt.AlignVCenter | Qt.AlignLeft, self.caption)
        if not self.paths:
            p.setPen(QColor(MUTED))
            p.drawText(self.rect(), Qt.AlignCenter, "No images found")


# ---------------------------------------------------------------- live chart
class Chart(QWidget):
    """Scrolling line chart with two series sharing the x axis."""

    def __init__(self, series, length=120):
        super().__init__()
        self.series = series  # list of (name, color, min, max)
        self.data = [deque([math.nan] * length, maxlen=length) for _ in series]
        self.setMinimumHeight(180)

    def append(self, values):
        for d, v in zip(self.data, values):
            d.append(v)
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(12, 28, -12, -12)
        p.fillRect(self.rect(), QColor(CARD))
        p.setPen(QPen(QColor("#2c3038"), 1))
        for i in range(5):
            y = r.top() + r.height() * i / 4
            p.drawLine(QPointF(r.left(), y), QPointF(r.right(), y))
        x_legend = 12
        for (name, color, lo, hi), d in zip(self.series, self.data):
            path, started = QPainterPath(), False
            n = len(d)
            for i, v in enumerate(d):
                if math.isnan(v):
                    continue
                x = r.left() + r.width() * i / (n - 1)
                y = r.bottom() - r.height() * (min(max(v, lo), hi) - lo) / (hi - lo)
                if started:
                    path.lineTo(x, y)
                else:
                    path.moveTo(x, y)
                    started = True
            p.setPen(QPen(QColor(color), 2))
            p.drawPath(path)
            last = next((v for v in reversed(d) if not math.isnan(v)), math.nan)
            label = f"{name}: {last:.1f}" if not math.isnan(last) else name
            p.drawText(QPointF(x_legend, 18), label)
            x_legend += 170


# ---------------------------------------------------------------- KPI tile
class Tile(QWidget):
    """Shows a value that animates towards each new reading."""

    def __init__(self, title, unit, fmt="{:.1f}"):
        super().__init__()
        self.title, self.unit, self.fmt = title, unit, fmt
        self.value = 0.0
        self._anim = QVariantAnimation(self, duration=500, easingCurve=QEasingCurve.OutCubic)
        self._anim.valueChanged.connect(self._on_value)
        self.setMinimumHeight(90)

    def set_value(self, v):
        if math.isnan(v):
            return
        self._anim.stop()
        self._anim.setStartValue(float(self.value))
        self._anim.setEndValue(float(v))
        self._anim.start()

    def _on_value(self, v):
        self.value = v
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(CARD))
        p.setPen(QColor(MUTED))
        font = QFont(self.font())
        font.setPixelSize(14)
        p.setFont(font)
        p.drawText(QRectF(14, 8, self.width() - 28, 24), Qt.AlignLeft, self.title)
        p.setPen(QColor(TEXT))
        font.setPixelSize(34)
        font.setBold(True)
        p.setFont(font)
        p.drawText(QRectF(14, 30, self.width() - 28, self.height() - 36), Qt.AlignLeft | Qt.AlignVCenter,
                   self.fmt.format(self.value) + " " + self.unit)


# ---------------------------------------------------------------- spinner / fps probe
class Spinner(QWidget):
    """Repaints at up to 60 Hz; counts how many frames are actually drawn."""

    def __init__(self):
        super().__init__()
        self.angle = 0.0
        self.frames = 0
        self._last = time.monotonic()
        self._timer = QTimer(self, interval=16, timerType=Qt.PreciseTimer)
        self._timer.timeout.connect(self._tick)
        self._timer.start()
        self.setFixedSize(44, 44)

    def _tick(self):
        now = time.monotonic()
        self.angle = (self.angle + 360.0 * (now - self._last)) % 360.0  # one turn per second
        self._last = now
        self.update()

    def paintEvent(self, event):
        self.frames += 1
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.translate(self.width() / 2, self.height() / 2)
        p.rotate(self.angle)
        p.setPen(QPen(QColor(ACCENT), 4, Qt.SolidLine, Qt.RoundCap))
        p.drawArc(QRectF(-16, -16, 32, 32), 0, 270 * 16)


# ---------------------------------------------------------------- main window
class Dashboard(QWidget):
    def __init__(self, args):
        super().__init__()
        self.args = args
        self.metrics = Metrics()
        self.paused = False

        paths = sorted(p for p in glob.glob(os.path.join(args.images, "**", "*"), recursive=True)
                       if p.lower().endswith((".jpg", ".jpeg", ".png")))

        self.setStyleSheet(f"""
            QWidget {{ background: {BG}; color: {TEXT}; font-size: 15px; }}
            QPushButton {{ background: {CARD}; border: 1px solid #343944; border-radius: 6px;
                           padding: 10px 18px; }}
            QPushButton:pressed {{ background: {ACCENT}; }}
            QLabel#title {{ font-size: 24px; font-weight: bold; }}
            QLabel#muted {{ color: {MUTED}; }}
        """)

        # Header
        title = QLabel("PYNQ-Z2 dashboard", objectName="title")
        self.clock = QLabel(objectName="muted")
        self.fps_label = QLabel(objectName="muted")
        self.spinner = Spinner()
        header = QHBoxLayout()
        header.addWidget(title)
        header.addStretch(1)
        header.addWidget(self.fps_label)
        header.addSpacing(16)
        header.addWidget(self.spinner)
        header.addSpacing(16)
        header.addWidget(self.clock)

        # Image panel
        self.image = ImageView(paths)
        self.image.clicked.connect(lambda: self.image.show_relative(1))
        prev_btn, next_btn = QPushButton("◀ Prev"), QPushButton("Next ▶")
        self.pause_btn = QPushButton("Pause")
        quit_btn = QPushButton("Quit")
        prev_btn.clicked.connect(lambda: self.image.show_relative(-1))
        next_btn.clicked.connect(lambda: self.image.show_relative(1))
        self.pause_btn.clicked.connect(self.toggle_pause)
        quit_btn.clicked.connect(QApplication.instance().quit)
        buttons = QHBoxLayout()
        for b in (prev_btn, next_btn, self.pause_btn):
            buttons.addWidget(b)
        buttons.addStretch(1)
        buttons.addWidget(quit_btn)
        left = QVBoxLayout()
        left.addWidget(self.image, 1)
        left.addLayout(buttons)

        # Metrics panel
        self.chart = Chart([("CPU %", ACCENT, 0, 100), ("Temp °C", ACCENT2, 30, 80)])
        self.tile_cpu = Tile("CPU load", "%", "{:.0f}")
        self.tile_temp = Tile("Chip temperature", "°C")
        self.tile_mem = Tile("Memory used", "MB", "{:.0f}")
        self.tile_load = Tile("Image decode", "ms", "{:.0f}")
        tiles = QGridLayout()
        tiles.setSpacing(10)
        for i, t in enumerate((self.tile_cpu, self.tile_temp, self.tile_mem, self.tile_load)):
            tiles.addWidget(t, i // 2, i % 2)
        right = QVBoxLayout()
        right.addWidget(self.chart, 1)
        right.addLayout(tiles)

        body = QHBoxLayout()
        body.addLayout(left, 3)
        body.addSpacing(12)
        body.addLayout(right, 2)

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 14, 18, 14)
        root.addLayout(header)
        root.addSpacing(8)
        root.addLayout(body, 1)

        # Timers
        self.metrics_timer = QTimer(self, interval=200, timeout=self.update_metrics)
        self.metrics_timer.start()
        self.slide_timer = QTimer(self, interval=int(args.interval * 1000),
                                  timeout=lambda: self.image.show_relative(1))
        self.slide_timer.start()
        self.fps_timer = QTimer(self, interval=1000, timeout=self.update_fps)
        self.fps_timer.start()
        self._fps_history = deque(maxlen=60)
        self._cpu_history = deque(maxlen=60)
        self._frames_last = 0
        if args.stats > 0:
            QTimer(self, interval=int(args.stats * 1000), timeout=self.print_stats).start()
        if args.duration > 0:
            QTimer.singleShot(int(args.duration * 1000), QApplication.instance().quit)
        QTimer.singleShot(0, lambda: self.image.show_relative(1))
        self._metric_ticks = 0

    def toggle_pause(self):
        self.paused = not self.paused
        self.slide_timer.stop() if self.paused else self.slide_timer.start()
        self.pause_btn.setText("Resume" if self.paused else "Pause")

    def keyPressEvent(self, event):
        key = event.key()
        if key in (Qt.Key_Q, Qt.Key_Escape):
            QApplication.instance().quit()
        elif key == Qt.Key_Right:
            self.image.show_relative(1)
        elif key == Qt.Key_Left:
            self.image.show_relative(-1)
        elif key == Qt.Key_Space:
            self.toggle_pause()

    def update_metrics(self):
        cpu = self.metrics.cpu_percent()
        temp = self.metrics.temperature_c()
        self.chart.append([cpu, temp])
        self._cpu_history.append(cpu)
        self._metric_ticks += 1
        if self._metric_ticks % 5 == 0:  # tiles once per second
            self.tile_cpu.set_value(sum(list(self._cpu_history)[-5:]) / 5)
            self.tile_temp.set_value(temp)
            self.tile_mem.set_value(self.metrics.mem_used_mb())
            if self.image.load_times:
                self.tile_load.set_value(1000 * self.image.load_times[-1])
            self.clock.setText(time.strftime("%H:%M:%S"))

    def update_fps(self):
        fps = self.spinner.frames - self._frames_last
        self._frames_last = self.spinner.frames
        self._fps_history.append(fps)
        self.fps_label.setText(f"UI {fps} fps")

    def print_stats(self):
        n = int(self.args.stats)
        fps = list(self._fps_history)[-n:]
        cpu = list(self._cpu_history)[-5 * n:]
        loads = list(self.image.load_times)
        print(f"[{time.strftime('%H:%M:%S')}] UI fps avg {sum(fps) / max(len(fps), 1):.1f} "
              f"min {min(fps, default=0)} | CPU avg {sum(cpu) / max(len(cpu), 1):.0f}% | "
              f"image decode avg {1000 * sum(loads) / max(len(loads), 1):.0f} ms", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", default="/home/xilinx/jupyter_notebooks")
    ap.add_argument("--interval", type=float, default=4.0)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--stats", type=float, default=5.0)
    args = ap.parse_args()

    app = QApplication(sys.argv[:1])
    win = Dashboard(args)
    win.showFullScreen()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
