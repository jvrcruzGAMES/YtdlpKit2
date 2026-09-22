"""Compatibility boundary for yt-dlp's intentionally unstable plugin internals."""

import hashlib
import importlib
import importlib.metadata
import json
import os
import pkgutil
import sys
import traceback
from pathlib import Path


def _text(value):
    return None if value is None else str(value)


def _origin(cls):
    module = sys.modules.get(cls.__module__)
    return _text(getattr(module, '__file__', None))


def _distribution_index():
    result = []
    for dist in importlib.metadata.distributions():
        try:
            files = list(dist.files or ())
            roots = {str(Path(dist.locate_file(f)).resolve()) for f in files}
            # Source installs synthesized by YtdlpKit2 now contain RECORD, but
            # retain a constrained root fallback for installations created by
            # older library versions. Only use it when the distribution has no
            # authoritative file inventory.
            fallback_root = (str(Path(dist.locate_file('')).resolve())
                             if not files else None)
            result.append((dist.metadata.get('Name'), dist.version, roots,
                           fallback_root, dist.metadata))
        except Exception:
            continue
    return result


def _owner(origin, distributions):
    if not origin:
        return None
    target = str(Path(origin).resolve())
    for name, version, files, fallback_root, metadata in distributions:
        owned = target in files
        if fallback_root:
            try:
                owned = Path(target).is_relative_to(fallback_root)
            except (TypeError, ValueError):
                owned = False
        if owned:
            return {'name': name, 'version': version, 'metadata': {
                'description': metadata.get('Summary'),
                'author': metadata.get('Author'),
                'license': metadata.get('License'),
                'homepage': metadata.get('Home-page'),
            }}
    return None


def _module_candidates():
    from yt_dlp.plugins import iter_modules
    for kind in ('extractor', 'postprocessor'):
        try:
            for finder, name, _ in iter_modules(kind):
                if not any(part.startswith('_') for part in name.split('.')):
                    yield finder, name
        except Exception:
            continue


def _clear_external_providers():
    try:
        from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers
        _jsc_providers.value = {
            key: cls for key, cls in _jsc_providers.value.items()
            if not cls.__module__.startswith('yt_dlp_plugins.')
        }
    except Exception:
        pass


def _refresh():
    import yt_dlp.extractor
    import yt_dlp.postprocessor
    from yt_dlp.globals import all_plugins_loaded, plugin_specs

    errors = []
    _clear_external_providers()
    for name in tuple(sys.modules):
        if name.startswith('yt_dlp_plugins.'):
            del sys.modules[name]
    importlib.invalidate_caches()

    # Probe imports ourselves because yt-dlp intentionally logs and suppresses failures.
    loaded = {'extractor': {}, 'postprocessor': {}}
    from yt_dlp.plugins import get_regular_classes
    for finder, name in _module_candidates():
        try:
            spec = finder.find_spec(name)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            kind = name.split('.')[1]
            suffix = plugin_specs.value[kind].suffix
            loaded[kind].update(get_regular_classes(module, name, suffix))
        except Exception:
            sys.modules.pop(name, None)
            errors.append({'module': name, 'error': traceback.format_exc()})

    for kind, spec in plugin_specs.value.items():
        regular = loaded.get(kind, {})
        spec.plugin_destination.value = regular
        builtins = {
            name: cls for name, cls in spec.destination.value.items()
            if not getattr(cls, '__module__', '').startswith('yt_dlp_plugins.')
        }
        # yt-dlp prepends plugin extractors to its ordered registry. GenericIE
        # matches every URL, so placing built-ins first makes every otherwise
        # valid plugin unreachable. Preserve plugin overrides while appending
        # only built-ins that the plugins did not replace.
        merged = dict(regular)
        merged.update((name, cls) for name, cls in builtins.items()
                      if name not in merged)
        spec.destination.value = merged
    all_plugins_loaded.value = True
    return errors


def _extractor(cls):
    return {
        'class_name': cls.__name__, 'module_name': cls.__module__,
        'ie_name': _text(getattr(cls, 'IE_NAME', None)),
        'description': _text(getattr(cls, 'IE_DESC', None)),
        'valid_url_pattern': _text(getattr(cls, '_VALID_URL', None)),
        'working': bool(getattr(cls, '_WORKING', True)),
        # Accessing an absent attribute through yt-dlp's lazy extractor proxy
        # emits a misleading fallback warning. Class dictionaries are enough
        # for optional descriptor metadata and have no loader side effects.
        'age_limit': cls.__dict__.get('AGE_LIMIT'),
        'supports_search': bool(cls.__dict__.get('_SEARCH_KEY')),
        'origin': _origin(cls),
    }


def _postprocessor(name, cls):
    return {
        'class_name': cls.__name__, 'module_name': cls.__module__,
        'registered_name': name[:-2] if name.endswith('PP') else name,
        'description': _text(getattr(cls, '__doc__', None)), 'origin': _origin(cls),
    }


def _providers():
    try:
        from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers
    except Exception:
        return []
    providers = []
    for key, cls in _jsc_providers.value.items():
        module = cls.__module__
        external = module.startswith('yt_dlp_plugins.')
        # Constructing a provider requires a live extractor. Mirror the plugin's
        # platform prerequisite without instantiating it. CPython reports
        # sys.platform == "ios" on iOS even though os.uname().sysname is Darwin.
        available = True
        if getattr(cls, 'PROVIDER_NAME', '') == 'apple-webkit-jsi':
            available = (bool(getattr(cls, 'IS_AVAIL', True))
                         and hasattr(os, 'uname')
                         and os.uname().sysname == 'Darwin'
                         and int(os.uname().release.split('.', 1)[0]) >= 20)
        providers.append({
            'name': _text(getattr(cls, 'PROVIDER_NAME', key)),
            'version': _text(getattr(cls, 'PROVIDER_VERSION', None)),
            'module_name': module, 'provider_kind': 'youtube-jsc',
            'available': available, 'external': external,
            'metadata': {'registry_key': str(key), 'origin': _origin(cls) or ''},
        })
    return providers


def _inventory(refresh):
    errors = _refresh() if refresh else []
    from yt_dlp.globals import plugin_ies, plugin_pps
    distributions = _distribution_index()
    capabilities = []
    for cls in plugin_ies.value.values():
        capabilities.append(('extractor', _extractor(cls), cls))
    for name, cls in plugin_pps.value.items():
        capabilities.append(('postprocessor', _postprocessor(name, cls), cls))
    for value in _providers():
        if value['external']:
            cls = sys.modules.get(value['module_name'])
            capabilities.append(('java_script_challenge_provider', value, None))

    groups = {}
    for kind, value, cls in capabilities:
        origin = value.get('origin') or value.get('metadata', {}).get('origin')
        owner = _owner(origin, distributions)
        module = value['module_name']
        key = (owner or {}).get('name') or origin or module
        group = groups.setdefault(key, {
            'stable_key': hashlib.sha256(key.encode()).hexdigest()[:24],
            'distribution': owner, 'modules': set(), 'capabilities': [], 'errors': [],
        })
        group['modules'].add(module)
        group['capabilities'].append({'kind': kind, 'value': value})

    for error in errors:
        module = error['module']
        key = f'broken:{module}'
        groups[key] = {
            'stable_key': hashlib.sha256(key.encode()).hexdigest()[:24],
            'distribution': None, 'modules': {module}, 'capabilities': [],
            'errors': [error['error']],
        }
    plugins = []
    for group in groups.values():
        group['modules'] = sorted(group['modules'])
        plugins.append(group)
    return {'plugins': plugins, 'scan_errors': [], 'plugin_paths': list_plugin_paths()}


def refresh_plugins():
    return json.dumps(_inventory(True), sort_keys=True)


def list_plugins():
    return json.dumps(_inventory(False), sort_keys=True)


def list_plugin_paths():
    try:
        from yt_dlp.plugins import directories
        return [str(path) for path in directories()]
    except Exception:
        return []


def matching_extractors(url):
    _refresh()
    from yt_dlp.extractor import gen_extractor_classes
    result = []
    for cls in gen_extractor_classes():
        try:
            if cls.suitable(url):
                result.append({'extractor': _extractor(cls),
                               'plugin': cls.__module__.startswith('yt_dlp_plugins.'),
                               'generic': cls.__name__ == 'GenericIE'})
        except Exception:
            continue
    return json.dumps(result, sort_keys=True)
