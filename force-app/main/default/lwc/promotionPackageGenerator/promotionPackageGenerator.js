import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import generatePackageXml from '@salesforce/apex/PromotionPackageService.generatePackageXml';
import getIgnoredComponents from '@salesforce/apex/PromotionPackageService.getIgnoredComponents';
import startZipGeneration from '@salesforce/apex/PromotionPackageService.startZipGeneration';
import checkZipStatus from '@salesforce/apex/PromotionPackageService.checkZipStatus';

const ZIP_MESSAGES = [
    'Queuing zip generation...',
    'Fetching promotion branch from GitHub...',
    'Collecting component files...',
    'Creating zip archive...',
    'Uploading to Salesforce...',
    'Almost done...',
];

export default class PromotionPackageGenerator extends LightningElement {
    @api recordId;

    @track isLoading             = false;
    @track loadingMessage        = '';
    @track errorMessage          = '';
    @track downloadUrl           = '';
    @track destructiveDownloadUrl = '';
    @track zipDownloadUrl        = '';
    @track showIgnoredPrompt     = false;
    @track ignoredComponents     = [];

    _pollInterval   = null;
    _msgInterval    = null;
    _msgIndex       = 0;
    _jobExecutionId = null;

    handleClose() {
        this._stopAll();
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    get ignoredCount() {
        return this.ignoredComponents.length;
    }

    get showButtons() {
        return !this.isLoading && !this.showIgnoredPrompt;
    }

    async handleGeneratePackageXml() {
        this.isLoading              = true;
        this.errorMessage           = '';
        this.downloadUrl            = '';
        this.destructiveDownloadUrl = '';
        this.showIgnoredPrompt      = false;
        this.ignoredComponents      = [];
        this.loadingMessage         = 'Checking the promotion for ignored changes...';
        try {
            const ignored = await getIgnoredComponents({ promotionId: this.recordId });
            if (ignored && ignored.length > 0) {
                this.ignoredComponents = ignored.map((c) => ({
                    key:   (c.story || '') + '|' + c.metadataType + '|' + c.name,
                    label: c.metadataType + ': ' + c.name + (c.story ? ' (' + c.story + ')' : '')
                }));
                this.showIgnoredPrompt = true;
                this.isLoading = false;
                return;
            }
        } catch (err) {
            this.errorMessage = this._extractError(err);
            this.isLoading = false;
            return;
        }
        await this._generatePackageXml(false);
    }

    handleExcludeIgnored() {
        this.showIgnoredPrompt = false;
        return this._generatePackageXml(true);
    }

    handleIncludeIgnored() {
        this.showIgnoredPrompt = false;
        return this._generatePackageXml(false);
    }

    handleCancelPrompt() {
        this.showIgnoredPrompt = false;
        this.ignoredComponents = [];
    }

    async _generatePackageXml(excludeIgnored) {
        this.isLoading              = true;
        this.errorMessage           = '';
        this.loadingMessage         = 'Reading Promotion JSON and building package.xml...';
        try {
            const result    = await generatePackageXml({ promotionId: this.recordId, excludeIgnored });
            const base      = window.location.origin + '/sfc/servlet.shepherd/version/download/';
            const pkgCvId   = result && result.packageCvId   ? String(result.packageCvId)   : null;
            const destCvId  = result && result.destructiveCvId ? String(result.destructiveCvId) : null;
            if (pkgCvId) {
                this.downloadUrl = base + pkgCvId + '?oper=DOWNLOAD';
            }
            if (destCvId) {
                this.destructiveDownloadUrl = base + destCvId + '?oper=DOWNLOAD';
            }
            if (!pkgCvId && !destCvId) {
                this.errorMessage = 'No components found in the Promotion JSON.';
            }
        } catch (err) {
            this.errorMessage = this._extractError(err);
        } finally {
            this.isLoading = false;
        }
    }

    async handleGenerateDeploymentZip() {
        this.isLoading      = true;
        this.errorMessage   = '';
        this.zipDownloadUrl = '';
        this._msgIndex      = 0;
        this._pollCount     = 0;
        this.loadingMessage = ZIP_MESSAGES[0];

        try {
            this._jobExecutionId = await startZipGeneration({ promotionId: this.recordId });
            this._startMessageCycle();
            this._pollInterval = setInterval(() => { this._poll(); }, 5000);
        } catch (err) {
            this.errorMessage = this._extractError(err);
            this.isLoading = false;
        }
    }

    _startMessageCycle() {
        this._msgInterval = setInterval(() => {
            if (this._msgIndex < ZIP_MESSAGES.length - 1) {
                this._msgIndex++;
                this.loadingMessage = ZIP_MESSAGES[this._msgIndex];
            }
        }, 4000);
    }

    async _poll() {
        this._pollCount = (this._pollCount || 0) + 1;
        if (this._pollCount > 120) {
            this._stopAll();
            this.errorMessage = 'Timed out after 10 min. Check the Promotion Files tab — the zip may still be generating in the background.';
            this.isLoading = false;
            return;
        }
        try {
            const result = await checkZipStatus({ jobExecutionId: this._jobExecutionId, promotionId: this.recordId });
            const status = result.status || '';
            const ok     = ['Successful', 'Success', 'Completed'].includes(status);
            const fail   = ['Failed', 'Error', 'Cancelled', 'Aborted', 'Skipped'].includes(status);

            if (ok) {
                this._stopAll();
                if (result.cvId) {
                    this.zipDownloadUrl = window.location.origin
                        + '/sfc/servlet.shepherd/version/download/' + result.cvId + '?oper=DOWNLOAD';
                } else {
                    this.errorMessage = 'Job completed but no deployment.zip found. Check Apex Jobs in Setup.';
                }
                this.isLoading = false;
            } else if (fail) {
                this._stopAll();
                this.errorMessage = result.error || ('Zip generation ' + status + '. Check Apex Jobs in Setup for details.');
                this.isLoading = false;
            }
        } catch (err) {
            this._stopAll();
            this.errorMessage = this._extractError(err);
            this.isLoading = false;
        }
    }

    _stopAll() {
        if (this._pollInterval) { clearInterval(this._pollInterval); this._pollInterval = null; }
        if (this._msgInterval)  { clearInterval(this._msgInterval);  this._msgInterval  = null; }
    }

    _extractError(err) {
        if (err && err.body && err.body.message) return err.body.message;
        if (err && err.message) return err.message;
        return String(err);
    }
}
