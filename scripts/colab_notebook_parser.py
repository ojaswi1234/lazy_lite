#!/usr/bin/env python3
"""
Jupyter Notebook (.ipynb) Parser and Serializer
Handles parsing and serializing Colab notebook JSON files
"""

import json
import sys
from typing import Dict, List, Any, Optional
from datetime import datetime


class NotebookParser:
    """Parser for Jupyter/Colab notebook files"""
    
    def __init__(self):
        self.default_notebook = {
            "metadata": {
                "kernelspec": {
                    "display_name": "Python 3",
                    "language": "python",
                    "name": "python3"
                },
                "colab": {
                    "provenance": []
                },
                "language_info": {
                    "name": "python",
                    "version": "3.8.0"
                }
            },
            "nbformat": 4,
            "nbformat_minor": 0,
            "cells": []
        }
    
    def parse(self, file_path: str) -> Dict[str, Any]:
        """Parse .ipynb file and return notebook data"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            # Validate notebook structure
            if not self._validate_notebook(data):
                raise ValueError("Invalid notebook structure")
            
            return data
        except FileNotFoundError:
            raise FileNotFoundError(f"Notebook file not found: {file_path}")
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON in notebook file: {e}")
    
    def parse_string(self, json_string: str) -> Dict[str, Any]:
        """Parse notebook from JSON string"""
        try:
            data = json.loads(json_string)
            if not self._validate_notebook(data):
                raise ValueError("Invalid notebook structure")
            return data
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON string: {e}")
    
    def serialize(self, notebook_data: Dict[str, Any]) -> str:
        """Serialize notebook data to JSON string"""
        if not self._validate_notebook(notebook_data):
            raise ValueError("Invalid notebook structure")
        
        return json.dumps(notebook_data, indent=2, ensure_ascii=False)
    
    def save(self, notebook_data: Dict[str, Any], file_path: str) -> None:
        """Save notebook data to .ipynb file"""
        json_string = self.serialize(notebook_data)
        
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(json_string)
    
    def _validate_notebook(self, data: Dict[str, Any]) -> bool:
        """Validate notebook structure"""
        required_keys = ['nbformat', 'nbformat_minor', 'cells']
        
        if not all(key in data for key in required_keys):
            return False
        
        if not isinstance(data['cells'], list):
            return False
        
        # Validate each cell
        for cell in data['cells']:
            if not self._validate_cell(cell):
                return False
        
        return True
    
    def _validate_cell(self, cell: Dict[str, Any]) -> bool:
        """Validate cell structure"""
        required_keys = ['cell_type', 'source']
        
        if not all(key in cell for key in required_keys):
            return False
        
        if cell['cell_type'] not in ['markdown', 'code']:
            return False
        
        if not isinstance(cell['source'], (list, str)):
            return False
        
        return True
    
    def create_cell(self, cell_type: str, source: str = "", execution_count: Optional[int] = None) -> Dict[str, Any]:
        """Create a new cell"""
        if isinstance(source, str):
            source = [source]
        
        cell = {
            "cell_type": cell_type,
            "metadata": {},
            "source": source
        }
        
        if cell_type == "code":
            cell["execution_count"] = execution_count
            cell["outputs"] = []
        
        return cell
    
    def add_cell(self, notebook_data: Dict[str, Any], cell_type: str, source: str = "", index: Optional[int] = None) -> Dict[str, Any]:
        """Add a cell to the notebook"""
        cell = self.create_cell(cell_type, source)
        
        if index is None:
            notebook_data['cells'].append(cell)
        else:
            notebook_data['cells'].insert(index, cell)
        
        return notebook_data
    
    def remove_cell(self, notebook_data: Dict[str, Any], index: int) -> Dict[str, Any]:
        """Remove a cell from the notebook"""
        if 0 <= index < len(notebook_data['cells']):
            notebook_data['cells'].pop(index)
        return notebook_data
    
    def move_cell(self, notebook_data: Dict[str, Any], from_index: int, to_index: int) -> Dict[str, Any]:
        """Move a cell to a new position"""
        if 0 <= from_index < len(notebook_data['cells']) and 0 <= to_index < len(notebook_data['cells']):
            cell = notebook_data['cells'].pop(from_index)
            notebook_data['cells'].insert(to_index, cell)
        return notebook_data
    
    def update_cell_source(self, notebook_data: Dict[str, Any], index: int, source: str) -> Dict[str, Any]:
        """Update the source of a cell"""
        if 0 <= index < len(notebook_data['cells']):
            if isinstance(source, str):
                source = [source]
            notebook_data['cells'][index]['source'] = source
        return notebook_data
    
    def update_cell_output(self, notebook_data: Dict[str, Any], index: int, outputs: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Update the outputs of a code cell"""
        if 0 <= index < len(notebook_data['cells']):
            if notebook_data['cells'][index]['cell_type'] == 'code':
                notebook_data['cells'][index]['outputs'] = outputs
        return notebook_data
    
    def get_cell_count(self, notebook_data: Dict[str, Any]) -> int:
        """Get the number of cells in the notebook"""
        return len(notebook_data['cells'])
    
    def get_cell(self, notebook_data: Dict[str, Any], index: int) -> Optional[Dict[str, Any]]:
        """Get a cell by index"""
        if 0 <= index < len(notebook_data['cells']):
            return notebook_data['cells'][index]
        return None
    
    def create_new_notebook(self, name: str = "Untitled") -> Dict[str, Any]:
        """Create a new notebook with default structure"""
        notebook = self.default_notebook.copy()
        notebook['metadata']['colab']['name'] = name
        
        # Add a markdown cell with the title
        title_cell = self.create_cell('markdown', f"# {name}\n")
        notebook['cells'].append(title_cell)
        
        # Add a code cell
        code_cell = self.create_cell('code', "# Your code here\n")
        notebook['cells'].append(code_cell)
        
        return notebook


def main():
    """CLI interface for the notebook parser"""
    if len(sys.argv) < 2:
        print("Usage: python colab_notebook_parser.py <command> [args]")
        print("Commands:")
        print("  parse <file>              - Parse notebook file")
        print("  create <name> <output>    - Create new notebook")
        print("  validate <file>           - Validate notebook file")
        sys.exit(1)
    
    command = sys.argv[1]
    parser = NotebookParser()
    
    if command == "parse":
        if len(sys.argv) < 3:
            print("Error: parse command requires file path")
            sys.exit(1)
        
        file_path = sys.argv[2]
        try:
            notebook = parser.parse(file_path)
            print(json.dumps(notebook, indent=2))
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
    
    elif command == "create":
        if len(sys.argv) < 4:
            print("Error: create command requires name and output path")
            sys.exit(1)
        
        name = sys.argv[2]
        output_path = sys.argv[3]
        
        try:
            notebook = parser.create_new_notebook(name)
            parser.save(notebook, output_path)
            print(f"Created notebook: {output_path}")
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
    
    elif command == "validate":
        if len(sys.argv) < 3:
            print("Error: validate command requires file path")
            sys.exit(1)
        
        file_path = sys.argv[2]
        try:
            notebook = parser.parse(file_path)
            print(f"Valid notebook with {parser.get_cell_count(notebook)} cells")
        except Exception as e:
            print(f"Invalid notebook: {e}", file=sys.stderr)
            sys.exit(1)
    
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()