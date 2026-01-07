#!/usr/bin/env python3
"""
Conftest for persistence tests - imports fixtures from parent directory
"""

# Import all fixtures from parent conftest
import sys
import os

# Add parent directory to path
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, parent_dir)

# Import all fixtures from parent conftest
from conftest import *