#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Запуск fhOS в VirtualBox.

Создаёт (если нужно) виртуальную машину, подключает к ней build/fhos.iso
и включает её. По умолчанию используется VirtualBox (VBoxManage).

    python run_vm.py            # создать ВМ (если нет) и запустить
    python run_vm.py --headless # запустить без окна
    python run_vm.py --remove   # удалить ВМ
"""

import os
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.abspath(__file__))
ISO = os.path.join(ROOT, "build", "fhos.iso")
VM_NAME = "fhOS"


def find_vboxmanage():
    which = shutil.which("VBoxManage")
    if which:
        return which
    candidates = [
        r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
        r"C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe",
        os.path.expandvars(r"%ProgramFiles%\Oracle\VirtualBox\VBoxManage.exe"),
        "/usr/bin/VBoxManage",
        "/usr/local/bin/VBoxManage",
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


def vm_exists(vbm):
    out = subprocess.run([vbm, "list", "vms"], capture_output=True, text=True).stdout
    return ('"%s"' % VM_NAME) in out


def create_vm(vbm):
    print("Создаю виртуальную машину '%s'..." % VM_NAME)
    subprocess.run([vbm, "createvm", "--name", VM_NAME, "--ostype", "Other",
                    "--register"], check=True)
    subprocess.run([vbm, "modifyvm", VM_NAME,
                    "--memory", "32", "--vram", "16",
                    "--boot1", "dvd", "--boot2", "none",
                    "--boot3", "none", "--boot4", "none",
                    "--audio-driver", "none", "--usb", "off",
                    "--graphicscontroller", "vboxvga"], check=True)
    subprocess.run([vbm, "storagectl", VM_NAME, "--name", "IDE",
                    "--add", "ide", "--controller", "PIIX4"], check=True)
    subprocess.run([vbm, "storageattach", VM_NAME, "--storagectl", "IDE",
                    "--port", "0", "--device", "0", "--type", "dvddrive",
                    "--medium", ISO], check=True)


def main():
    args = sys.argv[1:]
    if "--remove" in args:
        vbm = find_vboxmanage()
        if not vbm:
            print("ОШИБКА: не найден VBoxManage.")
            sys.exit(1)
        subprocess.run([vbm, "unregistervm", VM_NAME, "--delete"])
        print("ВМ '%s' удалена." % VM_NAME)
        return

    if not os.path.isfile(ISO):
        print("ОШИБКА: не найден %s" % ISO)
        print("Сначала соберите образ:  python build.py")
        sys.exit(1)

    vbm = find_vboxmanage()
    if not vbm:
        print("ОШИБКА: не найден VBoxManage (VirtualBox).")
        print("Установите VirtualBox или запустите ISO вручную (см. README.md).")
        sys.exit(1)
    print("VBoxManage:", vbm)

    if not vm_exists(vbm):
        create_vm(vbm)
    else:
        # обновляем подключённый ISO на случай пересборки
        subprocess.run([vbm, "storageattach", VM_NAME, "--storagectl", "IDE",
                        "--port", "0", "--device", "0", "--type", "dvddrive",
                        "--medium", ISO], check=False)

    mode = "headless" if "--headless" in args else "gui"
    print("Запускаю ВМ '%s' (%s)..." % (VM_NAME, mode))
    subprocess.run([vbm, "startvm", VM_NAME, "--type", mode], check=True)


if __name__ == "__main__":
    main()
