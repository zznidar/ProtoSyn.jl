from collections import OrderedDict
from node_serializable import Serializable
from PyQt5.QtWidgets import *


class QDMNodeContentWidget(QWidget, Serializable):
    def __init__(self, node, parent = None):
        self.node = node
        super().__init__(parent)

        self.initUI()

    def initUI(self):
        self.layout = QVBoxLayout()
        self.layout.setContentsMargins(0,0,0,0)
        self.setLayout(self.layout)

        self.wdg_label = QLabel("Probability of Mutation")
        self.layout.addWidget(self.wdg_label)
        self.layout.addWidget(QDMTextEdit("1.0"))

    def setEditingFlag(self, value):
        self.node.scene.getView().editingFlag = value

    def serialize(self):
        return OrderedDict([
    ])

    def deserialize(self, data, hashmap={}, restore_id = True):
        return True


class QDMTextEdit(QTextEdit):
    def focusInEvent(self, event):
        self.parentWidget().setEditingFlag(True)
        super().focusInEvent(event)

    def focusOutEvent(self, event):
        self.parentWidget().setEditingFlag(False)
        super().focusOutEvent(event)