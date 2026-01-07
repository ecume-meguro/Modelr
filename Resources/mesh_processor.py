#!/usr/bin/env python3
"""
Mesh Processor for Modelr
===========================

This module uses trimesh to analyze and process 3D meshes:
- Identify separate mesh components (connected components)
- Get statistics for each component
- Delete selected components
- Keep only the largest component
- Export to various formats (OBJ, GLB, STL, PLY)
"""

import os
import sys
import json
import argparse
from typing import Dict, Any, List, Optional
from pathlib import Path

try:
    import numpy as np
    import trimesh
except ImportError as e:
    print(json.dumps({
        "success": False,
        "error": f"Missing required package: {e}. Please install trimesh and numpy."
    }), flush=True)
    sys.exit(1)


def analyze_mesh(mesh_path: str) -> Dict[str, Any]:
    """
    Analyze a mesh and return information about its components.

    Returns:
        Dictionary with:
        - success: bool
        - components: list of component info dicts
        - total_vertices: int
        - total_faces: int
        - bounds: [min_xyz, max_xyz]
    """
    try:
        # Load the mesh
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            # If it's a scene, combine all geometries
            mesh = mesh.dump(concatenate=True)

        if mesh is None or not hasattr(mesh, 'vertices') or len(mesh.vertices) == 0:
            return {"success": False, "error": "Failed to load mesh or mesh is empty"}

        # Split into connected components
        components_list = mesh.split(only_watertight=False)

        if not components_list or len(components_list) == 0:
            # Single component
            components_list = [mesh]

        components_info = []
        for i, component in enumerate(components_list):
            if not hasattr(component, 'vertices') or len(component.vertices) == 0:
                continue

            bounds = component.bounds.tolist() if hasattr(component, 'bounds') and component.bounds is not None else [[0,0,0], [0,0,0]]
            center = component.centroid.tolist() if hasattr(component, 'centroid') else [0, 0, 0]

            # Calculate component size (diagonal of bounding box)
            if hasattr(component, 'bounds') and component.bounds is not None:
                size = np.linalg.norm(component.bounds[1] - component.bounds[0])
            else:
                size = 0

            info = {
                "index": i,
                "vertex_count": len(component.vertices),
                "face_count": len(component.faces) if hasattr(component, 'faces') else 0,
                "bounds_min": bounds[0],
                "bounds_max": bounds[1],
                "center": center,
                "size": float(size),
                "is_watertight": bool(component.is_watertight) if hasattr(component, 'is_watertight') else False
            }
            components_info.append(info)

        # Sort by size (largest first)
        components_info.sort(key=lambda x: x["vertex_count"], reverse=True)

        # Re-assign indices after sorting
        for i, comp in enumerate(components_info):
            comp["index"] = i

        total_bounds = mesh.bounds.tolist() if hasattr(mesh, 'bounds') and mesh.bounds is not None else [[0,0,0], [0,0,0]]

        return {
            "success": True,
            "component_count": len(components_info),
            "components": components_info,
            "total_vertices": len(mesh.vertices),
            "total_faces": len(mesh.faces) if hasattr(mesh, 'faces') else 0,
            "bounds_min": total_bounds[0],
            "bounds_max": total_bounds[1]
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def delete_components(mesh_path: str, indices_to_delete: List[int], output_path: str) -> Dict[str, Any]:
    """
    Delete specified components from a mesh and save the result.

    Args:
        mesh_path: Path to input mesh
        indices_to_delete: List of component indices to remove
        output_path: Where to save the result

    Returns:
        Dictionary with success status and info about remaining mesh
    """
    try:
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            mesh = mesh.dump(concatenate=True)

        components = mesh.split(only_watertight=False)
        if not components or len(components) == 0:
            components = [mesh]

        # Sort by vertex count (same as analyze) to match indices
        components = sorted(components, key=lambda x: len(x.vertices) if hasattr(x, 'vertices') else 0, reverse=True)

        # Filter out deleted components
        indices_set = set(indices_to_delete)
        remaining = [comp for i, comp in enumerate(components) if i not in indices_set]

        if not remaining:
            return {"success": False, "error": "Cannot delete all components"}

        # Combine remaining components
        if len(remaining) == 1:
            result_mesh = remaining[0]
        else:
            result_mesh = trimesh.util.concatenate(remaining)

        # Export
        result_mesh.export(output_path)

        return {
            "success": True,
            "output_path": output_path,
            "remaining_components": len(remaining),
            "remaining_vertices": len(result_mesh.vertices),
            "remaining_faces": len(result_mesh.faces) if hasattr(result_mesh, 'faces') else 0
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def keep_largest(mesh_path: str, output_path: str) -> Dict[str, Any]:
    """
    Keep only the largest component (by vertex count) and save.
    """
    try:
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            mesh = mesh.dump(concatenate=True)

        components = mesh.split(only_watertight=False)
        if not components or len(components) == 0:
            components = [mesh]

        # Find largest by vertex count
        largest = max(components, key=lambda x: len(x.vertices) if hasattr(x, 'vertices') else 0)

        # Export
        largest.export(output_path)

        return {
            "success": True,
            "output_path": output_path,
            "remaining_vertices": len(largest.vertices),
            "remaining_faces": len(largest.faces) if hasattr(largest, 'faces') else 0,
            "original_components": len(components)
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def export_mesh(mesh_path: str, output_path: str, format: str) -> Dict[str, Any]:
    """
    Export mesh to a different format.

    Supported formats: obj, glb, gltf, stl, ply, off
    """
    try:
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            mesh = mesh.dump(concatenate=True)

        # Ensure output has correct extension
        format = format.lower()
        if not output_path.lower().endswith(f'.{format}'):
            output_path = f"{output_path}.{format}"

        # Export
        if format in ['glb', 'gltf']:
            # For GLTF/GLB, we need to wrap in a scene
            scene = trimesh.Scene([mesh])
            scene.export(output_path)
        else:
            mesh.export(output_path)

        return {
            "success": True,
            "output_path": output_path,
            "format": format,
            "vertices": len(mesh.vertices),
            "faces": len(mesh.faces) if hasattr(mesh, 'faces') else 0
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def extract_component(mesh_path: str, component_index: int, output_path: str) -> Dict[str, Any]:
    """
    Extract a single component and save it as a separate file.
    """
    try:
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            mesh = mesh.dump(concatenate=True)

        components = mesh.split(only_watertight=False)
        if not components or len(components) == 0:
            components = [mesh]

        # Sort by vertex count to match indices from analyze
        components = sorted(components, key=lambda x: len(x.vertices) if hasattr(x, 'vertices') else 0, reverse=True)

        if component_index < 0 or component_index >= len(components):
            return {"success": False, "error": f"Component index {component_index} out of range (0-{len(components)-1})"}

        component = components[component_index]
        component.export(output_path)

        return {
            "success": True,
            "output_path": output_path,
            "vertices": len(component.vertices),
            "faces": len(component.faces) if hasattr(component, 'faces') else 0
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def extract_all_components(mesh_path: str, output_dir: str) -> Dict[str, Any]:
    """
    Extract all components as separate OBJ files for visualization.
    Returns paths to each component file.
    """
    try:
        mesh = trimesh.load(mesh_path, force='mesh')

        if isinstance(mesh, trimesh.Scene):
            mesh = mesh.dump(concatenate=True)

        components = mesh.split(only_watertight=False)
        if not components or len(components) == 0:
            components = [mesh]

        # Sort by vertex count (largest first)
        components = sorted(components, key=lambda x: len(x.vertices) if hasattr(x, 'vertices') else 0, reverse=True)

        # Ensure output directory exists
        os.makedirs(output_dir, exist_ok=True)

        component_files = []
        for i, comp in enumerate(components):
            if not hasattr(comp, 'vertices') or len(comp.vertices) == 0:
                continue

            output_path = os.path.join(output_dir, f"component_{i}.obj")
            comp.export(output_path)

            component_files.append({
                "index": i,
                "path": output_path,
                "vertex_count": len(comp.vertices),
                "face_count": len(comp.faces) if hasattr(comp, 'faces') else 0
            })

        return {
            "success": True,
            "component_count": len(component_files),
            "components": component_files
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def main():
    parser = argparse.ArgumentParser(description='Mesh processing tool using trimesh')
    parser.add_argument('command', choices=['analyze', 'delete', 'keep_largest', 'export', 'extract', 'extract_all'],
                        help='Command to execute')
    parser.add_argument('--input', '-i', required=True, help='Input mesh path')
    parser.add_argument('--output', '-o', help='Output mesh path or directory')
    parser.add_argument('--indices', '-d', help='Comma-separated list of component indices to delete')
    parser.add_argument('--format', '-f', default='obj', help='Export format (obj, glb, stl, ply)')
    parser.add_argument('--component', '-c', type=int, help='Component index for extraction')

    args = parser.parse_args()

    result: Dict[str, Any] = {"success": False, "error": "Unknown error"}

    if args.command == 'analyze':
        result = analyze_mesh(args.input)

    elif args.command == 'delete':
        if not args.output:
            result = {"success": False, "error": "Output path required for delete command"}
        elif not args.indices:
            result = {"success": False, "error": "Indices required for delete command"}
        else:
            indices = [int(i.strip()) for i in args.indices.split(',')]
            result = delete_components(args.input, indices, args.output)

    elif args.command == 'keep_largest':
        if not args.output:
            result = {"success": False, "error": "Output path required for keep_largest command"}
        else:
            result = keep_largest(args.input, args.output)

    elif args.command == 'export':
        if not args.output:
            result = {"success": False, "error": "Output path required for export command"}
        else:
            result = export_mesh(args.input, args.output, args.format)

    elif args.command == 'extract':
        if not args.output:
            result = {"success": False, "error": "Output path required for extract command"}
        elif args.component is None:
            result = {"success": False, "error": "Component index required for extract command"}
        else:
            result = extract_component(args.input, args.component, args.output)

    elif args.command == 'extract_all':
        if not args.output:
            result = {"success": False, "error": "Output directory required for extract_all command"}
        else:
            result = extract_all_components(args.input, args.output)

    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
