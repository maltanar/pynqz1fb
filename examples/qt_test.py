#!/usr/bin/env python3
"""Minimal PyQt5 test for the PYNQ framebuffer.

Run as root on the board:
    QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0 python3 qt_test.py

Shows red/green/blue bars (to check the colour order) and a button that quits.
"""
import sys
from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton

app = QApplication(sys.argv)
win = QWidget()
layout = QVBoxLayout(win)

bars = QHBoxLayout()
for name, color in (("RED", "#ff0000"), ("GREEN", "#00ff00"), ("BLUE", "#0000ff")):
    label = QLabel(name)
    label.setStyleSheet(f"background: {color}; color: white; font-size: 32px; padding: 40px;")
    bars.addWidget(label)
layout.addLayout(bars)

quit_button = QPushButton("Quit")
quit_button.setStyleSheet("font-size: 24px; padding: 12px;")
quit_button.clicked.connect(app.quit)
layout.addWidget(quit_button)

win.showFullScreen()
sys.exit(app.exec_())
