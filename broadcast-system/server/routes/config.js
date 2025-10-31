const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs').promises;

const router = express.Router();

// Configure multer for file uploads
const storage = multer.diskStorage({
  destination: async (req, file, cb) => {
    const uploadDir = path.join(__dirname, '../../uploads');
    try {
      await fs.mkdir(uploadDir, { recursive: true });
      cb(null, uploadDir);
    } catch (error) {
      cb(error);
    }
  },
  filename: (req, file, cb) => {
    const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
    cb(null, file.fieldname + '-' + uniqueSuffix + path.extname(file.originalname));
  }
});

const upload = multer({ 
  storage: storage,
  limits: {
    fileSize: 10 * 1024 * 1024 // 10MB limit
  },
  fileFilter: (req, file, cb) => {
    // Allow only specific file types
    const allowedTypes = /jpeg|jpg|png|gif|json|txt|mp3|wav|mp4/;
    const extname = allowedTypes.test(path.extname(file.originalname).toLowerCase());
    const mimetype = allowedTypes.test(file.mimetype);

    if (mimetype && extname) {
      return cb(null, true);
    } else {
      cb(new Error('Only images, audio, video, and config files are allowed'));
    }
  }
});

module.exports = () => {
  // Get system configuration
  router.get('/system', async (req, res) => {
    try {
      const config = {
        server: {
          version: require('../../package.json').version,
          environment: process.env.NODE_ENV || 'development',
          mediamtxUrl: process.env.MEDIAMTX_URL || 'http://localhost:8888',
          port: process.env.PORT || 3000
        },
        features: {
          recording: true,
          streaming: true,
          commentary: true,
          multiCamera: true,
          sceneComposition: true
        },
        limits: {
          maxCameras: 16,
          maxStreams: 8,
          maxCommentators: 4,
          maxScenes: 50
        },
        paths: {
          config: './config',
          uploads: './uploads',
          recordings: './recordings',
          logs: './logs'
        }
      };

      res.json({
        success: true,
        data: config
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get all configuration files
  router.get('/files', async (req, res) => {
    try {
      const configDir = path.join(__dirname, '../../config');
      const files = await fs.readdir(configDir);
      
      const configFiles = [];
      for (const file of files) {
        if (file.endsWith('.json')) {
          const filePath = path.join(configDir, file);
          const stats = await fs.stat(filePath);
          configFiles.push({
            name: file,
            path: filePath,
            size: stats.size,
            modified: stats.mtime,
            type: path.extname(file).substring(1)
          });
        }
      }

      res.json({
        success: true,
        data: configFiles
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get specific configuration file
  router.get('/files/:filename', async (req, res) => {
    try {
      const filename = req.params.filename;
      const filePath = path.join(__dirname, '../../config', filename);
      
      // Security check - ensure file is in config directory
      const resolvedPath = path.resolve(filePath);
      const configDir = path.resolve(path.join(__dirname, '../../config'));
      
      if (!resolvedPath.startsWith(configDir)) {
        return res.status(403).json({
          success: false,
          error: 'Access denied'
        });
      }

      const content = await fs.readFile(filePath, 'utf8');
      const stats = await fs.stat(filePath);

      res.json({
        success: true,
        data: {
          filename: filename,
          content: JSON.parse(content),
          size: stats.size,
          modified: stats.mtime
        }
      });
    } catch (error) {
      if (error.code === 'ENOENT') {
        return res.status(404).json({
          success: false,
          error: 'Configuration file not found'
        });
      }
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Update configuration file
  router.put('/files/:filename', async (req, res) => {
    try {
      const filename = req.params.filename;
      const { content } = req.body;
      
      if (!content) {
        return res.status(400).json({
          success: false,
          error: 'Content is required'
        });
      }

      const filePath = path.join(__dirname, '../../config', filename);
      
      // Security check
      const resolvedPath = path.resolve(filePath);
      const configDir = path.resolve(path.join(__dirname, '../../config'));
      
      if (!resolvedPath.startsWith(configDir)) {
        return res.status(403).json({
          success: false,
          error: 'Access denied'
        });
      }

      // Validate JSON
      let jsonContent;
      try {
        jsonContent = typeof content === 'string' ? JSON.parse(content) : content;
      } catch (parseError) {
        return res.status(400).json({
          success: false,
          error: 'Invalid JSON format'
        });
      }

      // Create backup
      const backupDir = path.join(__dirname, '../../config/backups');
      await fs.mkdir(backupDir, { recursive: true });
      
      try {
        const originalContent = await fs.readFile(filePath, 'utf8');
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const backupPath = path.join(backupDir, `${filename}.${timestamp}.backup`);
        await fs.writeFile(backupPath, originalContent);
      } catch (backupError) {
        console.warn('Failed to create backup:', backupError.message);
      }

      // Write new content
      await fs.writeFile(filePath, JSON.stringify(jsonContent, null, 2));

      res.json({
        success: true,
        message: `Configuration file ${filename} updated successfully`
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Upload configuration file
  router.post('/files/upload', upload.single('config'), async (req, res) => {
    try {
      if (!req.file) {
        return res.status(400).json({
          success: false,
          error: 'No file uploaded'
        });
      }

      const uploadedFile = req.file;
      const targetFilename = req.body.filename || uploadedFile.originalname;
      
      // Validate file type
      if (!targetFilename.endsWith('.json')) {
        await fs.unlink(uploadedFile.path); // Clean up uploaded file
        return res.status(400).json({
          success: false,
          error: 'Only JSON configuration files are allowed'
        });
      }

      // Read and validate JSON
      const content = await fs.readFile(uploadedFile.path, 'utf8');
      let jsonContent;
      try {
        jsonContent = JSON.parse(content);
      } catch (parseError) {
        await fs.unlink(uploadedFile.path); // Clean up uploaded file
        return res.status(400).json({
          success: false,
          error: 'Invalid JSON format'
        });
      }

      // Move to config directory
      const configPath = path.join(__dirname, '../../config', targetFilename);
      await fs.rename(uploadedFile.path, configPath);

      res.json({
        success: true,
        message: `Configuration file ${targetFilename} uploaded successfully`,
        data: {
          filename: targetFilename,
          size: uploadedFile.size
        }
      });
    } catch (error) {
      // Clean up uploaded file on error
      if (req.file && req.file.path) {
        try {
          await fs.unlink(req.file.path);
        } catch (cleanupError) {
          console.warn('Failed to clean up uploaded file:', cleanupError.message);
        }
      }
      
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Export configuration (download all configs as zip)
  router.get('/export', async (req, res) => {
    try {
      const configDir = path.join(__dirname, '../../config');
      const files = await fs.readdir(configDir);
      
      const configs = {};
      for (const file of files) {
        if (file.endsWith('.json') && !file.includes('.backup')) {
          const filePath = path.join(configDir, file);
          const content = await fs.readFile(filePath, 'utf8');
          configs[file] = JSON.parse(content);
        }
      }

      const exportData = {
        exportDate: new Date().toISOString(),
        version: require('../../package.json').version,
        configs: configs
      };

      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Content-Disposition', 'attachment; filename="broadcast-config-export.json"');
      res.json(exportData);
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Import configuration (restore from export)
  router.post('/import', upload.single('configExport'), async (req, res) => {
    try {
      if (!req.file) {
        return res.status(400).json({
          success: false,
          error: 'No export file uploaded'
        });
      }

      const content = await fs.readFile(req.file.path, 'utf8');
      let exportData;
      
      try {
        exportData = JSON.parse(content);
      } catch (parseError) {
        await fs.unlink(req.file.path);
        return res.status(400).json({
          success: false,
          error: 'Invalid export file format'
        });
      }

      if (!exportData.configs) {
        await fs.unlink(req.file.path);
        return res.status(400).json({
          success: false,
          error: 'Invalid export file - missing configs'
        });
      }

      // Create backup of current configs
      const backupDir = path.join(__dirname, '../../config/backups');
      await fs.mkdir(backupDir, { recursive: true });
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

      const results = {
        imported: [],
        failed: [],
        backed_up: []
      };

      // Import each configuration file
      for (const [filename, config] of Object.entries(exportData.configs)) {
        try {
          const configPath = path.join(__dirname, '../../config', filename);
          
          // Create backup if file exists
          try {
            const existingContent = await fs.readFile(configPath, 'utf8');
            const backupPath = path.join(backupDir, `${filename}.${timestamp}.backup`);
            await fs.writeFile(backupPath, existingContent);
            results.backed_up.push(filename);
          } catch (backupError) {
            // File doesn't exist, no backup needed
          }

          // Write new config
          await fs.writeFile(configPath, JSON.stringify(config, null, 2));
          results.imported.push(filename);
          
        } catch (error) {
          results.failed.push({ filename, error: error.message });
        }
      }

      // Clean up uploaded file
      await fs.unlink(req.file.path);

      res.json({
        success: true,
        message: `Import completed. ${results.imported.length} files imported, ${results.failed.length} failed`,
        data: results
      });
    } catch (error) {
      // Clean up uploaded file on error
      if (req.file && req.file.path) {
        try {
          await fs.unlink(req.file.path);
        } catch (cleanupError) {
          console.warn('Failed to clean up uploaded file:', cleanupError.message);
        }
      }
      
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get system logs
  router.get('/logs', async (req, res) => {
    try {
      const { lines = 100, level = 'all' } = req.query;
      
      // This would read from actual log files in production
      const logs = [
        {
          timestamp: new Date().toISOString(),
          level: 'info',
          message: 'Broadcast system started',
          module: 'server'
        },
        {
          timestamp: new Date(Date.now() - 60000).toISOString(),
          level: 'info',
          message: 'Camera manager initialized',
          module: 'camera'
        },
        {
          timestamp: new Date(Date.now() - 120000).toISOString(),
          level: 'warn',
          message: 'Stream connection unstable',
          module: 'streaming'
        }
      ];

      const filteredLogs = level === 'all' ? logs : logs.filter(log => log.level === level);
      const limitedLogs = filteredLogs.slice(-parseInt(lines));

      res.json({
        success: true,
        data: {
          logs: limitedLogs,
          total: filteredLogs.length,
          filters: { lines: parseInt(lines), level }
        }
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Reset to defaults
  router.post('/reset', async (req, res) => {
    try {
      const { components } = req.body;
      
      if (!components || !Array.isArray(components)) {
        return res.status(400).json({
          success: false,
          error: 'Components array is required'
        });
      }

      const results = {
        reset: [],
        failed: []
      };

      // Create backup before reset
      const backupDir = path.join(__dirname, '../../config/backups');
      await fs.mkdir(backupDir, { recursive: true });
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

      for (const component of components) {
        try {
          const configFile = `${component}.json`;
          const configPath = path.join(__dirname, '../../config', configFile);
          
          // Create backup
          try {
            const existingContent = await fs.readFile(configPath, 'utf8');
            const backupPath = path.join(backupDir, `${configFile}.${timestamp}.backup`);
            await fs.writeFile(backupPath, existingContent);
          } catch (backupError) {
            // File doesn't exist, skip backup
          }

          // Delete config file to trigger default creation
          try {
            await fs.unlink(configPath);
          } catch (deleteError) {
            // File doesn't exist, that's fine
          }

          results.reset.push(component);
          
        } catch (error) {
          results.failed.push({ component, error: error.message });
        }
      }

      res.json({
        success: true,
        message: `Reset completed. ${results.reset.length} components reset, ${results.failed.length} failed`,
        data: results
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  return router;
};