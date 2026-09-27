package dev.flavordrake.app_updater;

import androidx.core.content.FileProvider;

/** A distinct class so the merged manifest never has two FileProvider entries with one name. */
public class UpdaterFileProvider extends FileProvider {}
