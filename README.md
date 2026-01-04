# Image Folder Captioner

This simple powershell script will intelligently help you caption images for building a LoRA. Built specifically for the z-Image Turbo model but it could be used with other models.

This was built for use with Nano-GPT subscriptions but you could easily modify the script to use pretty much any other API with minimal changes.

This doesn't just caption the images but attempts to define the character based on a few of the images in the directory and then uses that description and a wordbank to build the captions. Hopefully this will build cohesive character LoRAs.

## Installation
Just copy the script to a folder and run it.  If there are images in the folder that the script is in it will process those images. If, however, the script is in a root folder with multiple folders containing images it will prompt the user which folder to work in. That way you can have one version of the script and work in multiple child folders.
