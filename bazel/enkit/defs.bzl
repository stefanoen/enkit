load("@rules_pkg//:pkg.bzl", "pkg_tar")
load("@com_github_atlassian_bazel_tools//multirun:def.bzl", "multirun")
load("@io_bazel_rules_docker//container:container.bzl", "container_push")
load("@bazel_tools//tools/build_defs/hash:hash.bzl", "sha256", "tools")
load("//bazel/astore:defs.bzl", "astore_upload")
load("//bazel/utils:template.bzl", "template_expand", "template_tool")
load("//bazel/utils:validate.bzl", "validate_format", "validate_tool")

EnkitExtensionInfo = provider(
    doc = """Maintains the information necessary to use an enkit extension. """,
    fields = {
        "manifest": "File object pointing to the manfiest of the package.",
        "images": "List of digest files of the docker images used by this extension.",
        "tarball": "Target representing the rule responsible for creating the tarball.",
        "sha256": "File containing the sha256 of the generated tarball.",
    },
)

def _enkit_package_definition(ctx):
    sha = sha256(ctx, ctx.file.tarball)
    return [DefaultInfo(files = depset([sha])), EnkitExtensionInfo(manifest = ctx.attr.manifest, images = ctx.attr.images, tarball = ctx.attr.tarball, sha256 = sha)]

enkit_package_definition = rule(
    doc = """Provides the definition of an enkit package.

An enkit package is made by a manifest, one or more docker images, a tarball,
and a hash.

This rule creates computes the hash, and creates an EnkitExtensionInfo provider
defining the package, so that other rules can refer to it.
""",
    implementation = _enkit_package_definition,
    attrs = {
        "images": attr.label_list(
            doc = "Docker images this package depends on. List of Target objects.",
            allow_files = True,
        ),
        "tarball": attr.label(
            doc = "Tarball generated containing the manifest and all the files necessary.",
            allow_single_file = True,
            mandatory = True,
        ),
        "manifest": attr.label(
            doc = "Manifest file included in the tarball.",
            default = "manifest.yaml",
            allow_single_file = True,
        ),
        # Used internally, tool responsible for generating the sha256 hash.
        "sha256": tools["sha256"],
    },
)

def _enkit_config(ctx):
    outfile = ctx.attr.output
    if not outfile:
        outfile = ctx.file.config.basename

    output = ctx.actions.declare_file(outfile)
    expanded = ctx.actions.declare_file(outfile + ".expanded")

    subs = {}
    for package, name in ctx.attr.packages.items():
        subs[name + ".sha256"] = package[EnkitExtensionInfo].sha256

    expander = template_expand(ctx.file._expander, template = ctx.file.config, output = expanded, subs = subs)
    ctx.actions.run(**expander)
    validator = validate_format(ctx.file._validator, output, [expanded], strip = ".expanded")
    ctx.actions.run(**validator)

    return [DefaultInfo(files = depset([output]))]

enkit_config = rule(
    doc = """Expands and defines an enkit configuration file by expanding the hash of dependant packages.""",
    implementation = _enkit_config,
    attrs = {
        "output": attr.string(
            doc = "Name of the output file, which generally has to match the command.",
        ),
        "config": attr.label(
            doc = "An enkit configuration file to prepare.",
            allow_single_file = True,
        ),
        "packages": attr.label_keyed_string_dict(
            doc = "A dict like {'//enkit:package': 'name'} defining the enkit packages used in this config, and how to refer to them.",
            providers = [EnkitExtensionInfo],
        ),
        "_expander": template_tool,
        "_validator": validate_tool,
    },
)

def enkit_package(name, srcs, image = "", manifest = "maninfest.yaml", **kwargs):
    """Convenience macro to create a tarball usable as an enkit package extension.

    This macro creates two targets:
      - name + "-package" - containing a tarball of the package.
      - name + "-definition" - containing the sha256 of the package, and an EnkitExtensionInfo
        provider convenient for the embedding of the package in other enkit configs.

    Args:
      srcs: source files to include, generally shell scripts.
      image: optional, the label of a docker_push rule specifying an image whose hash to include.
      manifest: optional, the path of a manifest file to use.
      **kwargs: passed on to pkg_tar and enkit_package_definition, generally useful to define things like visibility..
    """
    tarball = name + "-package"
    images = []
    if image:
        images = [image + ".digest"]

    pkg_tar(
        name = tarball,
        extension = "tar.gz",
        srcs = srcs + [manifest] + images,
        **kwargs
    )
    enkit_package_definition(name = name + "-definition", tarball = ":" + tarball, images = images, manifest = manifest, **kwargs)

def enkit_config_upload(name, config, packages = [], astore = "", **kwargs):
    """Convenience macro to upload an enkit config to astore."""
    enkit_config(
        name = name,
        config = config,
        packages = packages,
        **kwargs
    )
    if astore:
        astore_upload(
            name = name + "-upload",
            dir = astore,
            targets = [":" + name],
            **kwargs
        )

def enkit_extension(name, srcs, manifest = "", astore = "", image = {}, **kwargs):
    """Convenience macro to upload a package to astore together with a docker image.

    Creates multiple targets:
      - name + "-image" - to build and push the container image to the registry.
      - name + "-upload" - to upload the package definition to astore.
      - name + "-package" - containing a tarball of the package.
      - name + "-definition" - containing the sha256 of the package, and an EnkitExtensionInfo
        provider convenient for the embedding of the package in other enkit configs.
      - name - that can be invoked with bazel build or run to upload the image to docker
        and the package to astore.

    Args:
      srcs: source files to include in the generated enkit_package.
      manifest: optional, path to a manifest file. "manifest.yaml" is assumed if unspecified.
      image: optional, a dict, containing all the parameters that would be passed to container_push().
      astore: optional, a string, containing the path of the directory where to push the package.
      **kwargs: passed to all the rules, to allow to define visibility and similar.
    """
    commands = []
    itarget = ""
    if image:
        iname = name + "-image"
        image.update(**kwargs)
        container_push(
            name = iname,
            **image
        )
        itarget = ":" + iname
        commands.append(itarget)

    enkit_package(
        name = name,
        srcs = srcs,
        image = itarget,
        manifest = manifest,
        **kwargs
    )
    if astore:
        astore_upload(
            name = name + "-upload",
            dir = astore,
            targets = [
                ":" + name + "-package",
            ],
            **kwargs
        )
        commands.append(name + "-upload")

    if commands:
        multirun(
            name = name,
            commands = commands,
            **kwargs
        )
