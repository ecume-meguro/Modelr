"""Exception classes for Modelr."""


class ModelLoadError(Exception):
    """Raised when a model fails to load."""

    pass


class ImageValidationError(Exception):
    """Raised when image validation fails."""

    pass


class GenerationError(Exception):
    """Raised when 3D generation fails."""

    pass


class OutOfMemoryError(Exception):
    """Raised when GPU memory is exhausted."""

    pass


class NetworkError(Exception):
    """Raised when network operations fail."""

    pass


class ProtocolError(Exception):
    """Raised when JSON protocol parsing fails."""

    pass
